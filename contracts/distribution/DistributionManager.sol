// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "../interfaces/IDistributionManager.sol";
import "../interfaces/IDatasetNFT.sol";
import "../interfaces/IFragmentNFT.sol";

contract DistributionManager is IDistributionManager, ReentrancyGuardUpgradeable, ContextUpgradeable {
    using SafeERC20 for IERC20;
    using EnumerableMap for EnumerableMap.Bytes32ToUintMap;
    using Address for address payable;

    event PaymentReceived();
    event PayoutSent(address indexed to, address token, uint256 amount);

    error BAD_SIGNATURE(bytes32 msgHash, address recoveredSigner);

    struct Payment {
        address token;
        uint256 distributionAmount;
        uint256 snapshotId;
        uint256 tagWeightsVersion;
    }

    IDatasetNFT public dataset;
    uint256 public datasetId;
    IFragmentNFT public fragmentNFT;
    uint256 public datasetOwnerPercentage;      // 100% = 1e18
    mapping(address token => uint256 amount) public pendingOwnerFee; // Amount available for claim by the owner
    Payment[] public payments;
    EnumerableMap.Bytes32ToUintMap[] internal versionedTagWeights;
    mapping(address => uint256) internal firstUnclaimed;

    modifier onlyDatasetOwner() {
        require(dataset.ownerOf(datasetId) == _msgSender(), "Not a Dataset owner");
        _;
    }

    modifier onlySubscriptionManager() {
        require(dataset.subscriptionManager(datasetId) == _msgSender(), "Only Subscription manager");
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(address dataset_, uint256 datasetId_) external initializer() {
        __ReentrancyGuard_init();
        dataset = IDatasetNFT(dataset_);
        datasetId = datasetId_;
        fragmentNFT = IFragmentNFT(dataset.fragmentNFT(datasetId));
    }

    /**
     * @notice Define how to distribute payment to different tags
     * The summ of weights should be 100%, and 100% is encoded as 1e18
     * @param tags tags participating in the payment distributions
     * @param weights weights of the tags
     */
    function setTagWeights(bytes32[] calldata tags, uint256[] calldata weights) external onlyDatasetOwner {
        EnumerableMap.Bytes32ToUintMap storage tagWeights = versionedTagWeights.push();
        uint256 weightSumm;
        for(uint256 i; i < weights.length; i++) {
            weightSumm += weights[i];
            tagWeights.set(tags[i], weights[i]);
        }
        require(weightSumm == 1e18, "Invalid weights summ");
    }

    /**
     * @notice Retrieves the respective weights of the provided tags
     * @param tags array with tags to retrieve their weights
     * @return weights array with the respective weights 
     */
    function getTagWeights(bytes32[] calldata tags) external view returns(uint256[] memory weights) {
        require(tags.length != 0, "No tags provided");
        EnumerableMap.Bytes32ToUintMap storage tagWeights = versionedTagWeights[versionedTagWeights.length - 1];
        uint256 tagsLength = tags.length;
        weights = new uint256[](tagsLength);
        for(uint256 i; i < tagsLength; i++) {
            bytes32 tag = tags[i];
            (, uint256 weight) = tagWeights.tryGet(tag);
            weights[i] = weight;
        }
    }

    /**
     * @notice Set percentage of each payment that should be sent to the Dataset Owner
     * @dev Percentages are encoded such that 100% is represented as 1e18
     * @param percentage The percentage to set (must be less than or equal to 50%)
     */
    function setDatasetOwnerPercentage(uint256 percentage) external onlyDatasetOwner {
        require(percentage <= 5e17, "Can't be higher than 50%");
        datasetOwnerPercentage = percentage;
    }

    /**
     * @notice Called by SubscriptionManager to initiate payment
     * @dev if token is address(0) - native currency, the amount should match the msg.value
     * otherwise DistributionManager should call `transferFrom()` to transfer the amount from sender
     * @param token Payment token ERC20, address(0) means native currency
     * @param amount Payment amount
     */
    function receivePayment(address token, uint256 amount) external payable onlySubscriptionManager nonReentrant {
        require(versionedTagWeights.length > 0, "tag weights not initialized");
        if(address(token) == address(0)){
            require(amount == msg.value, "value missmatch");
        } else {
            IERC20(token).safeTransferFrom(_msgSender(), address(this), amount);
        }
        uint256 snapshotId = fragmentNFT.snapshot();
        
        // Deployer fee
        uint256 deployerFee = (amount * dataset.deployerFeePercentage(datasetId)) / 1e18;
        if(deployerFee > 0) {
            address deployerFeeBeneficiary = dataset.deployerFeeBeneficiary();
            require(deployerFeeBeneficiary != address(0), "bad deployer fee beneficiary");
            _sendPayout(token, deployerFee, deployerFeeBeneficiary);
            amount -= deployerFee;
        }

        // Dataset owner fee
        if(amount > 0) {
            uint256 ownerAmount = amount * datasetOwnerPercentage / 1e18;
            pendingOwnerFee[token] += ownerAmount;
            amount -= ownerAmount;
        }

        // Fragment contributors fee
        if(amount > 0) {
            payments.push(Payment({
                token: token,
                distributionAmount: amount,
                snapshotId: snapshotId,
                tagWeightsVersion: versionedTagWeights.length-1
            }));
        }

        emit PaymentReceived();
    }

    function claimDatasetOwnerPayouts(
        address token, 
        uint256 amount, 
        address beneficiary, 
        uint256 sigValidSince, 
        uint256 sigValidTill,
        bytes calldata signature
    ) external onlyDatasetOwner nonReentrant {
        // Validate signature
        require(block.timestamp >= sigValidSince && block.timestamp <= sigValidTill, "signature overdue");
        require(pendingOwnerFee[token] >= amount, "not enough amount");
        bytes32 msgHash = _ownerClaimMessageHash(token, amount, beneficiary, sigValidSince, sigValidTill);
        address signer = ECDSA.recover(msgHash, signature);
        if(!dataset.isSigner(signer)) revert BAD_SIGNATURE(msgHash, signer);
        pendingOwnerFee[token] -= amount;
         _sendPayout(token, amount, beneficiary);
    }

    function claimDatasetOwnerAndFragmentPayouts(
        address token, 
        uint256 amount, 
        address beneficiary, 
        uint256 sigValidSince, 
        uint256 sigValidTill,
        bytes calldata ownerPayoutSignature,
        bytes calldata fragmentPayoutSignature
    ) external onlyDatasetOwner nonReentrant {
        // Validate Dataset Owner Payout signature
        require(block.timestamp >= sigValidSince && block.timestamp <= sigValidTill, "signature overdue");
        require(pendingOwnerFee[token] >= amount, "not enough amount");

        bytes32 msgHash1 = _ownerClaimMessageHash(token, amount, beneficiary, sigValidSince, sigValidTill);
        address signer1 = ECDSA.recover(msgHash1, ownerPayoutSignature);
        if(!dataset.isSigner(signer1)) revert BAD_SIGNATURE(msgHash1, signer1);

        bytes32 msgHash2 = _fragmentClaimMessageHash(_msgSender(), sigValidSince, sigValidTill);
        address signer2 = ECDSA.recover(msgHash2, fragmentPayoutSignature);
        if(signer1 != signer2 || !dataset.isSigner(signer2)) revert BAD_SIGNATURE(msgHash2, signer2);

        // Send Dataset Owner Fee
        pendingOwnerFee[token] -= amount;
         _sendPayout(token, amount, beneficiary);

        // Claim Fragment Fee
        _claimPayouts(_msgSender());
    }

    /**
     * @notice Claim all payouts (for Fragment owners)
     */
    function claimPayouts(uint256 sigValidSince, uint256 sigValidTill, bytes calldata signature) external nonReentrant {
        // Validate signature
        require(block.timestamp >= sigValidSince && block.timestamp <= sigValidTill, "signature overdue");
        bytes32 msgHash = _fragmentClaimMessageHash(_msgSender(), sigValidSince, sigValidTill);
        address signer = ECDSA.recover(msgHash, signature);
        if(!dataset.isSigner(signer)) revert BAD_SIGNATURE(msgHash, signer);

        // Claim payouts
        uint256 firstUnclaimedPayout = firstUnclaimed[_msgSender()];
        if(firstUnclaimedPayout >= payments.length) return; // Nothing to claim
        address collectToken = payments[firstUnclaimedPayout].token;
        uint256 collectAmount;
        for(uint256 i = firstUnclaimedPayout; i < payments.length; i++) {
            Payment storage p = payments[i];
            if(collectToken != p.token) {
                // Payment token changed, send what we've already collected
                _sendPayout(collectToken, collectAmount, _msgSender());
                collectToken = p.token;
                collectAmount = 0;
            }
            collectAmount += _calculatePayout(p, _msgSender());
        }

        firstUnclaimed[_msgSender()] = payments.length;

        // send collected and not sent yet
        _sendPayout(collectToken, collectAmount, _msgSender());
    }

    
    function calculatePayoutByToken(address token, address account) external view returns (uint256 collectAmount) {
        uint256 firstUnclaimedPayout = firstUnclaimed[account]; 
        
        if(firstUnclaimedPayout >= payments.length) return 0;

        for(uint256 i = firstUnclaimedPayout; i < payments.length; i++) {
            Payment storage p = payments[i];
            if(token == p.token) {
                collectAmount += _calculatePayout(p, account);
            }
        }
    }

    function _claimPayouts(address beneficiary) internal {
        // Claim payouts
        uint256 firstUnclaimedPayout = firstUnclaimed[beneficiary];
        if(firstUnclaimedPayout >= payments.length) return;  // Nothing to claim
        firstUnclaimed[beneficiary] = payments.length;       // Updating firstUnclaimed before sending any tokens to prevent reentrancy

        address collectToken = payments[firstUnclaimedPayout].token;
        uint256 collectAmount;
        for(uint256 i = firstUnclaimedPayout; i < payments.length; i++) {
            Payment storage p = payments[i];
            if(collectToken != p.token) {
                // Payment token changed, send what we've already collected
                _sendPayout(collectToken, collectAmount, beneficiary);
                collectToken = p.token;
                collectAmount = 0;
            }
            collectAmount += _calculatePayout(p, beneficiary);
        }
        // send collected and not sent yet
        _sendPayout(collectToken, collectAmount, beneficiary);
    }

    function _calculatePayout(Payment storage p, address account) internal view returns (uint256 payout) {
        uint256 paymentAmount = p.distributionAmount;
        EnumerableMap.Bytes32ToUintMap storage tagWeights = versionedTagWeights[p.tagWeightsVersion];
        bytes32[] memory tags = tagWeights.keys();
        uint256[] memory percentages = fragmentNFT.accountTagPercentageAt(p.snapshotId, account, tags);
        for(uint256 i; i < tags.length; i++) {
            bytes32 tag = tags[i];
            if(percentages[i] > 0){
                payout += paymentAmount * tagWeights.get(tag) * percentages[i] / 1e36;
            }
        }
    }

    function _sendPayout(address token, uint256 amount, address to) internal {
        if ( token == address(0) ) {
            payable(to).sendValue(amount);
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
        emit PayoutSent(to, token, amount);
    }

    function _clear(EnumerableMap.Bytes32ToUintMap storage map) private {
        bytes32[] memory keys = map.keys();
        for(uint256 i; i < keys.length; i++) {
            map.remove(keys[i]);
        }
    }


    function _ownerClaimMessageHash(
        address token, 
        uint256 amount,
        address beneficiary, 
        uint256 sigValidSince, 
        uint256 sigValidTill
    ) private view returns (bytes32) {
        return ECDSA.toEthSignedMessageHash(abi.encodePacked(
            block.chainid,
            address(this),
            token,
            amount,
            beneficiary,
            sigValidSince,
            sigValidTill
        ));
    }

    function _fragmentClaimMessageHash(address beneficiary, uint256 sigValidSince, uint256 sigValidTill) private view returns (bytes32) {
        return ECDSA.toEthSignedMessageHash(abi.encodePacked(
            block.chainid,
            address(this),
            beneficiary,
            sigValidSince,
            sigValidTill
        ));
    }
}