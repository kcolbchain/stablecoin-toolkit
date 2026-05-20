// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IBurnTollFloorPool {
    function depth(address stablecoin, address burnToken) external view returns (uint256);
    function buyAndBurn(address stablecoin, address burnToken, uint256 amount) external;
}

/**
 * @title BurnToll
 * @notice Optional mint/redeem toll extension that routes stablecoin toll revenue to a floor pool for buy-and-burn execution.
 * @dev The floor pool is an adapter so deployments can wire an AMM, aggregator, or treasury execution contract without changing the minter.
 */
contract BurnToll is Ownable {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_BPS = 10_000;

    uint256 public mintTollBps = 50;
    uint256 public redeemTollBps = 50;
    address public burnTokenAddress;
    address public floorPoolAddress;
    uint256 public floorPoolMinDepth;
    address public minter;

    event BurnTollConfigured(
        uint256 mintTollBps,
        uint256 redeemTollBps,
        address indexed burnTokenAddress,
        address indexed floorPoolAddress,
        uint256 floorPoolMinDepth
    );
    event MinterSet(address indexed minter);
    event TollRouted(
        address indexed stablecoin, address indexed burnToken, uint256 amount, bool isRedeem
    );

    error TollBpsTooHigh(uint256 tollBps);
    error NotMinter(address caller);
    error ZeroAddress();

    modifier onlyMinter() {
        if (msg.sender != minter) revert NotMinter(msg.sender);
        _;
    }

    constructor(address _burnTokenAddress, address _floorPoolAddress, uint256 _floorPoolMinDepth)
        Ownable(msg.sender)
    {
        _configure(50, 50, _burnTokenAddress, _floorPoolAddress, _floorPoolMinDepth);
    }

    /**
     * @notice Sets the minter allowed to call toll routing hooks.
     * @param _minter Minter contract address.
     */
    function setMinter(address _minter) external onlyOwner {
        if (_minter == address(0)) revert ZeroAddress();
        minter = _minter;
        emit MinterSet(_minter);
    }

    /**
     * @notice Updates toll rates and routing parameters.
     * @param _mintTollBps Mint toll in basis points.
     * @param _redeemTollBps Redeem toll in basis points.
     * @param _burnTokenAddress Token bought and burned by the floor pool.
     * @param _floorPoolAddress Floor pool adapter receiving stablecoin toll revenue.
     * @param _floorPoolMinDepth Minimum floor-pool depth required before toll collection.
     */
    function configure(
        uint256 _mintTollBps,
        uint256 _redeemTollBps,
        address _burnTokenAddress,
        address _floorPoolAddress,
        uint256 _floorPoolMinDepth
    ) external onlyOwner {
        _configure(
            _mintTollBps, _redeemTollBps, _burnTokenAddress, _floorPoolAddress, _floorPoolMinDepth
        );
    }

    /**
     * @notice Calculates the mint toll for an amount, returning zero when the floor pool is not sufficiently deep.
     * @param stablecoin Stablecoin being tolled.
     * @param amount Gross mint amount.
     */
    function previewMintToll(address stablecoin, uint256 amount) external view returns (uint256) {
        return _previewToll(stablecoin, amount, mintTollBps);
    }

    /**
     * @notice Calculates the redeem toll for an amount, returning zero when the floor pool is not sufficiently deep.
     * @param stablecoin Stablecoin being tolled.
     * @param amount Gross redeem amount.
     */
    function previewRedeemToll(address stablecoin, uint256 amount) external view returns (uint256) {
        return _previewToll(stablecoin, amount, redeemTollBps);
    }

    /**
     * @notice Routes a mint toll already transferred to this contract.
     * @param stablecoin Stablecoin toll token.
     * @param amount Toll amount.
     */
    function handleMintToll(address stablecoin, uint256 amount) external onlyMinter {
        _routeToll(stablecoin, amount, false);
    }

    /**
     * @notice Routes a redeem toll already transferred to this contract.
     * @param stablecoin Stablecoin toll token.
     * @param amount Toll amount.
     */
    function handleRedeemToll(address stablecoin, uint256 amount) external onlyMinter {
        _routeToll(stablecoin, amount, true);
    }

    function _configure(
        uint256 _mintTollBps,
        uint256 _redeemTollBps,
        address _burnTokenAddress,
        address _floorPoolAddress,
        uint256 _floorPoolMinDepth
    ) internal {
        if (_mintTollBps > MAX_BPS) revert TollBpsTooHigh(_mintTollBps);
        if (_redeemTollBps > MAX_BPS) revert TollBpsTooHigh(_redeemTollBps);
        if (_burnTokenAddress == address(0) || _floorPoolAddress == address(0)) {
            revert ZeroAddress();
        }

        mintTollBps = _mintTollBps;
        redeemTollBps = _redeemTollBps;
        burnTokenAddress = _burnTokenAddress;
        floorPoolAddress = _floorPoolAddress;
        floorPoolMinDepth = _floorPoolMinDepth;

        emit BurnTollConfigured(
            _mintTollBps, _redeemTollBps, _burnTokenAddress, _floorPoolAddress, _floorPoolMinDepth
        );
    }

    function _previewToll(address stablecoin, uint256 amount, uint256 tollBps)
        internal
        view
        returns (uint256)
    {
        if (tollBps == 0 || !_hasEnoughFloorPoolDepth(stablecoin)) {
            return 0;
        }
        return (amount * tollBps) / MAX_BPS;
    }

    function _hasEnoughFloorPoolDepth(address stablecoin) internal view returns (bool) {
        return IBurnTollFloorPool(floorPoolAddress).depth(stablecoin, burnTokenAddress)
            >= floorPoolMinDepth;
    }

    function _routeToll(address stablecoin, uint256 amount, bool isRedeem) internal {
        if (amount == 0) {
            return;
        }

        IERC20(stablecoin).safeTransfer(floorPoolAddress, amount);
        IBurnTollFloorPool(floorPoolAddress).buyAndBurn(stablecoin, burnTokenAddress, amount);
        emit TollRouted(stablecoin, burnTokenAddress, amount, isRedeem);
    }
}
