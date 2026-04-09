// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./ChainlinkPoRAdapter.sol";

/**
 * @title ReserveManager
 * @notice Multi-asset reserve tracking with proof of reserves and ratio enforcement.
 * @dev Part of kcolbchain/stablecoin-toolkit. Supports both manual attestation
 *      and Chainlink Proof of Reserves feeds via ChainlinkPoRAdapter.
 */
contract ReserveManager is Ownable {
    struct ReserveAsset {
        string name;
        uint256 amount;       // in stablecoin-equivalent units (6 decimals)
        uint256 lastUpdated;
        bool active;
    }

    mapping(bytes32 => ReserveAsset) public reserves;
    bytes32[] public reserveIds;

    uint256 public totalReserves;
    uint256 public totalSupplyTracked; // updated by Minter
    uint256 public minimumRatioBps;    // e.g. 10000 = 100%, 10500 = 105%

    /// @dev Chainlink PoR adapter for on-chain reserve verification
    ChainlinkPoRAdapter public porAdapter;
    /// @dev Canonical reserve asset ID for the Chainlink-backed reserve
    bytes32 public constant POR_RESERVE_ID = bytes32(0);

    event ReserveUpdated(bytes32 indexed assetId, string name, uint256 amount);
    event SupplyUpdated(uint256 newSupply);
    event MinimumRatioUpdated(uint256 newRatioBps);
    event PorAdapterSet(address indexed adapter);
    event PorReservePulled(uint256 amount, uint256 updatedAt);

    error ReserveRatioTooLow(uint256 currentRatioBps, uint256 requiredRatioBps);
    error PorAdapterNotSet();
    error PorFeedFailed(string reason);

    constructor(uint256 _minimumRatioBps) Ownable(msg.sender) {
        minimumRatioBps = _minimumRatioBps;
    }

    function addReserveAsset(bytes32 assetId, string calldata name, uint256 amount) external onlyOwner {
        if (!reserves[assetId].active) {
            reserveIds.push(assetId);
        }
        reserves[assetId] = ReserveAsset({
            name: name,
            amount: amount,
            lastUpdated: block.timestamp,
            active: true
        });
        _recalcTotal();
        emit ReserveUpdated(assetId, name, amount);
    }

    function updateReserve(bytes32 assetId, uint256 amount) external onlyOwner {
        require(reserves[assetId].active, "Asset not active");
        reserves[assetId].amount = amount;
        reserves[assetId].lastUpdated = block.timestamp;
        _recalcTotal();
        emit ReserveUpdated(assetId, reserves[assetId].name, amount);
    }

    function updateTrackedSupply(uint256 supply) external onlyOwner {
        totalSupplyTracked = supply;
        emit SupplyUpdated(supply);
    }

    function setMinimumRatio(uint256 ratioBps) external onlyOwner {
        minimumRatioBps = ratioBps;
        emit MinimumRatioUpdated(ratioBps);
    }

    /**
     * @notice Sets the Chainlink PoR adapter address.
     * @param adapter Address of the ChainlinkPoRAdapter contract.
     */
    function setPorAdapter(address adapter) external onlyOwner {
        if (adapter == address(0)) revert PorAdapterNotSet();
        porAdapter = ChainlinkPoRAdapter(adapter);
        emit PorAdapterSet(adapter);
    }

    /**
     * @notice Pulls reserve data from the configured Chainlink PoR feed and
     *         updates the canonical PoR reserve asset.
     * @dev The adapter returns values in feed decimals (8); this contract
     *      converts to stablecoin units (6) before storing.
     */
    function pullPorReserve() public onlyOwner returns (uint256 reserveAmount, uint256 updatedAt) {
        if (address(porAdapter) == address(0)) revert PorAdapterNotSet();

        (uint256 rawAmount, uint256 timestamp) = porAdapter.getLatestReserveAmount();

        // Convert from feed decimals (8) to stablecoin units (6)
        reserveAmount = rawAmount / 100;

        // Upsert the PoR reserve asset
        reserves[POR_RESERVE_ID] = ReserveAsset({
            name: "Chainlink PoR Reserve",
            amount: reserveAmount,
            lastUpdated: timestamp,
            active: true
        });

        // Add to reserveIds if new
        bool found = false;
        for (uint256 i = 0; i < reserveIds.length; i++) {
            if (reserveIds[i] == POR_RESERVE_ID) {
                found = true;
                break;
            }
        }
        if (!found) {
            reserveIds.push(POR_RESERVE_ID);
        }

        _recalcTotal();
        emit PorReservePulled(reserveAmount, timestamp);
        return (reserveAmount, timestamp);
    }

    function getReserveRatioBps() public view returns (uint256) {
        if (totalSupplyTracked == 0) return type(uint256).max;
        return (totalReserves * 10000) / totalSupplyTracked;
    }

    function checkReserveRatio() public view {
        uint256 ratio = getReserveRatioBps();
        if (ratio < minimumRatioBps) {
            revert ReserveRatioTooLow(ratio, minimumRatioBps);
        }
    }

    /**
     * @notice Convenience: pull from PoR and check reserve ratio in one call.
     */
    function pullPorReserveAndCheck() external onlyOwner {
        if (address(porAdapter) == address(0)) revert PorAdapterNotSet();
        pullPorReserve();
        checkReserveRatio();
    }

    function getReserveCount() external view returns (uint256) {
        return reserveIds.length;
    }

    function _recalcTotal() internal {
        uint256 total = 0;
        for (uint256 i = 0; i < reserveIds.length; i++) {
            if (reserves[reserveIds[i]].active) {
                total += reserves[reserveIds[i]].amount;
            }
        }
        totalReserves = total;
    }
}
