// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../ComplianceModule.sol";

/**
 * @title BrazilCompliance
 * @notice Brazil-specific compliance extension with hashed CPF validation and PIX settlement hooks.
 * @dev CPF values must be normalized and hashed off-chain. This contract never stores plaintext CPF.
 */
contract BrazilCompliance is ComplianceModule {
    bytes2 public constant BR = bytes2("BR");

    enum CPFStatus {
        None,
        Approved,
        Rejected
    }

    mapping(address => bytes32) public cpfHashOf;
    mapping(bytes32 => CPFStatus) public cpfStatus;

    event CPFUpdated(address indexed account, bytes32 indexed cpfHash, CPFStatus status);
    event PIXSettled(address indexed account, bytes32 indexed pixKey, uint256 amount);

    error InvalidCPFHash();
    error CPFNotApproved(address account, bytes32 cpfHash);

    constructor(uint256 maxTxAmount, uint256 dailyLimit) {
        geoConfigs[BR] =
            GeoConfig({allowed: true, maxTxAmount: maxTxAmount, dailyLimit: dailyLimit});
        emit GeoConfigUpdated(BR, true, maxTxAmount, dailyLimit);
    }

    /**
     * @notice Sets KYC and CPF status for a Brazil account in a single owner-gated operation.
     * @param account Wallet controlled by the CPF holder.
     * @param cpfHash Hash of the normalized CPF, computed off-chain.
     * @param kycStatus Base KYC status used by ComplianceModule.
     * @param status Brazil-specific CPF approval status.
     */
    function setBrazilKYC(address account, bytes32 cpfHash, KYCStatus kycStatus, CPFStatus status)
        external
        onlyOwner
    {
        if (cpfHash == bytes32(0)) revert InvalidCPFHash();

        addressInfo[account].kycStatus = kycStatus;
        addressInfo[account].geography = BR;
        cpfHashOf[account] = cpfHash;
        cpfStatus[cpfHash] = status;

        emit KYCUpdated(account, kycStatus);
        emit GeographySet(account, BR);
        emit CPFUpdated(account, cpfHash, status);
    }

    function setCPFStatus(bytes32 cpfHash, CPFStatus status) external onlyOwner {
        if (cpfHash == bytes32(0)) revert InvalidCPFHash();
        cpfStatus[cpfHash] = status;
        emit CPFUpdated(address(0), cpfHash, status);
    }

    function configureBrazil(bool allowed, uint256 maxTxAmount, uint256 dailyLimit)
        external
        onlyOwner
    {
        geoConfigs[BR] =
            GeoConfig({allowed: allowed, maxTxAmount: maxTxAmount, dailyLimit: dailyLimit});
        emit GeoConfigUpdated(BR, allowed, maxTxAmount, dailyLimit);
    }

    function checkCompliance(address account, uint256 amount) public view override {
        super.checkCompliance(account, amount);

        if (addressInfo[account].geography == BR) {
            bytes32 cpfHash = cpfHashOf[account];
            if (cpfHash == bytes32(0) || cpfStatus[cpfHash] != CPFStatus.Approved) {
                revert CPFNotApproved(account, cpfHash);
            }
        }
    }

    /**
     * @notice Emits a PIX settlement hook after confirming Brazil compliance.
     * @param account Account whose redemption/settlement is being paid.
     * @param pixKey Hash or off-chain identifier for the PIX key.
     * @param amount Settlement amount in stablecoin base units.
     */
    function settlePIX(address account, bytes32 pixKey, uint256 amount) external onlyOwner {
        checkCompliance(account, amount);
        emit PIXSettled(account, pixKey, amount);
    }
}
