// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IAggregatorV3.sol";
import "./Stablecoin.sol";

contract ChainlinkReserveProof is Ownable {
    AggregatorV3Interface public porFeed;
    Stablecoin public stablecoin;
    IERC20 public vaultAsset;

    uint256 public maxFeedStaleSeconds;

    event ReserveCheckPerformed(uint256 supply, uint256 reserves, bool backed);
    event PorFeedUpdated(address indexed feed);
    event VaultAssetUpdated(address indexed asset);
    event StalenessUpdated(uint256 seconds_);

    error FeedStale(uint256 updatedAt);
    error InvalidFeedAnswer();
    error ZeroAddress();

    constructor(
        address _stablecoin,
        address _vaultAsset,
        address _porFeed,
        address _admin,
        uint256 _maxFeedStaleSeconds
    ) Ownable(_admin) {
        if (_stablecoin == address(0) || _vaultAsset == address(0) || _porFeed == address(0))
            revert ZeroAddress();
        stablecoin = Stablecoin(_stablecoin);
        vaultAsset = IERC20(_vaultAsset);
        porFeed = AggregatorV3Interface(_porFeed);
        maxFeedStaleSeconds = _maxFeedStaleSeconds;
    }

    function setPorFeed(address _feed) external onlyOwner {
        if (_feed == address(0)) revert ZeroAddress();
        porFeed = AggregatorV3Interface(_feed);
        emit PorFeedUpdated(_feed);
    }

    function setVaultAsset(address _asset) external onlyOwner {
        if (_asset == address(0)) revert ZeroAddress();
        vaultAsset = IERC20(_asset);
        emit VaultAssetUpdated(_asset);
    }

    function setStaleness(uint256 _seconds) external onlyOwner {
        maxFeedStaleSeconds = _seconds;
        emit StalenessUpdated(_seconds);
    }

    function isFullyBacked() external returns (bool) {
        (uint256 supply, uint256 reserves, bool backed) = checkReserves();
        return backed;
    }

    function checkReserves() public returns (uint256 supply, uint256 reserves, bool backed) {
        supply = stablecoin.totalSupply();

        reserves = _readProofOfReserves();

        backed = reserves >= supply;

        emit ReserveCheckPerformed(supply, reserves, backed);
    }

    function _readProofOfReserves() internal view returns (uint256) {
        (, int256 answer, , uint256 updatedAt, ) = porFeed.latestRoundData();
        if (answer < 0) revert InvalidFeedAnswer();
        if (updatedAt + maxFeedStaleSeconds < block.timestamp) revert FeedStale(updatedAt);

        return uint256(answer);
    }

    function checkReservesWithVaultBalance() external view returns (
        uint256 supply,
        uint256 porReserves,
        uint256 vaultBalance,
        bool backed
    ) {
        supply = stablecoin.totalSupply();
        porReserves = _readProofOfReserves();
        vaultBalance = vaultAsset.balanceOf(address(stablecoin));
        backed = vaultBalance >= supply && porReserves >= supply;
    }
}
