// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title ComplianceModule
 * @notice KYC status, geography-based restrictions, transaction limits, sanctions.
 * @dev Part of kcolbchain/stablecoin-toolkit
 */
contract ComplianceModule is Ownable {
    enum KYCStatus {
        None,
        Pending,
        Approved,
        Rejected
    }

    struct AddressInfo {
        KYCStatus kycStatus;
        bytes2 geography; // ISO 3166-1 alpha-2 (e.g. "IN", "US")
        bool sanctioned;
    }

    struct GeoConfig {
        bool allowed;
        uint256 maxTxAmount; // max per transaction (6 decimals)
        uint256 dailyLimit; // max per day (6 decimals)
    }

    mapping(address => AddressInfo) public addressInfo;
    mapping(bytes2 => GeoConfig) public geoConfigs;
    mapping(address => mapping(uint256 => uint256)) public dailySpent; // address -> day -> amount

    event KYCUpdated(address indexed account, KYCStatus status);
    event GeographySet(address indexed account, bytes2 geo);
    event GeoConfigUpdated(bytes2 indexed geo, bool allowed, uint256 maxTx, uint256 dailyLimit);
    event Sanctioned(address indexed account);
    event Unsanctioned(address indexed account);

    error NotKYCApproved(address account);
    error GeographyRestricted(bytes2 geo);
    error ExceedsTxLimit(uint256 amount, uint256 max);
    error ExceedsDailyLimit(uint256 spent, uint256 limit);
    error AddressSanctioned(address account);

    constructor() Ownable(msg.sender) {}

    function setKYC(address account, KYCStatus status) external onlyOwner {
        addressInfo[account].kycStatus = status;
        emit KYCUpdated(account, status);
    }

    function setGeography(address account, bytes2 geo) external onlyOwner {
        addressInfo[account].geography = geo;
        emit GeographySet(account, geo);
    }

    function configureGeography(bytes2 geo, bool allowed, uint256 maxTx, uint256 dailyLimit)
        external
        onlyOwner
    {
        geoConfigs[geo] = GeoConfig(allowed, maxTx, dailyLimit);
        emit GeoConfigUpdated(geo, allowed, maxTx, dailyLimit);
    }

    function sanction(address account) external onlyOwner {
        addressInfo[account].sanctioned = true;
        emit Sanctioned(account);
    }

    function unsanction(address account) external onlyOwner {
        addressInfo[account].sanctioned = false;
        emit Unsanctioned(account);
    }

    function checkCompliance(address account, uint256 amount) public view virtual {
        AddressInfo storage info = addressInfo[account];

        if (info.sanctioned) revert AddressSanctioned(account);
        if (info.kycStatus != KYCStatus.Approved) revert NotKYCApproved(account);

        bytes2 geo = info.geography;
        if (geo != bytes2(0)) {
            GeoConfig storage gc = geoConfigs[geo];
            if (!gc.allowed) revert GeographyRestricted(geo);
            if (gc.maxTxAmount > 0 && amount > gc.maxTxAmount) {
                revert ExceedsTxLimit(amount, gc.maxTxAmount);
            }
            uint256 today = block.timestamp / 1 days;
            uint256 spent = dailySpent[account][today];
            if (gc.dailyLimit > 0 && spent + amount > gc.dailyLimit) {
                revert ExceedsDailyLimit(spent + amount, gc.dailyLimit);
            }
        }
    }

    function recordSpend(address account, uint256 amount) external onlyOwner {
        uint256 today = block.timestamp / 1 days;
        dailySpent[account][today] += amount;
    }
}
