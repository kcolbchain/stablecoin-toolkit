// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./ReserveManager.sol";
import "./ChainlinkPoRAdapter.sol";

interface KeeperCompatibleInterface {
    function checkUpkeep(bytes calldata checkData) external view returns (bool upkeepNeeded, bytes memory performData);
    function performUpkeep(bytes calldata performData) external;
}

contract ChainlinkReserveKeeper is KeeperCompatibleInterface, Ownable {
    ReserveManager public reserveManager;
    ChainlinkPoRAdapter public porAdapter;

    uint256 public minRatioBps;
    uint256 public checkInterval;
    uint256 public lastCheck;

    event ReserveCheckTriggered(uint256 ratio, bool backed);
    event ParametersUpdated(uint256 minRatioBps, uint256 checkInterval);

    error ZeroAddress();

    constructor(
        address _reserveManager,
        address _porAdapter,
        address _admin,
        uint256 _minRatioBps,
        uint256 _checkInterval
    ) Ownable(_admin) {
        if (_reserveManager == address(0) || _porAdapter == address(0)) revert ZeroAddress();
        reserveManager = ReserveManager(_reserveManager);
        porAdapter = ChainlinkPoRAdapter(_porAdapter);
        minRatioBps = _minRatioBps;
        checkInterval = _checkInterval;
        lastCheck = block.timestamp;
    }

    function setParameters(uint256 _minRatioBps, uint256 _checkInterval) external onlyOwner {
        minRatioBps = _minRatioBps;
        checkInterval = _checkInterval;
        emit ParametersUpdated(_minRatioBps, _checkInterval);
    }

    function checkUpkeep(bytes calldata) external view override returns (bool upkeepNeeded, bytes memory performData) {
        if (block.timestamp < lastCheck + checkInterval) {
            return (false, "");
        }
        try porAdapter.getLatestReserveAmount() returns (uint256 reserveAmount, uint256) {
            uint256 supply = reserveManager.totalSupplyTracked();
            uint256 ratio = supply == 0 ? 10000 : (reserveAmount / 100) * 10000 / supply;
            upkeepNeeded = ratio < minRatioBps;
            performData = abi.encode(ratio, reserveAmount);
        } catch {
            upkeepNeeded = true;
            performData = abi.encode(0, 0);
        }
    }

    function performUpkeep(bytes calldata performData) external override {
        lastCheck = block.timestamp;
        (uint256 ratio, uint256 reserveAmount) = abi.decode(performData, (uint256, uint256));
        emit ReserveCheckTriggered(ratio, reserveAmount > 0);
    }
}
