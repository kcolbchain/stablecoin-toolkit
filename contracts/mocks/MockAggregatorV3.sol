// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../interfaces/AggregatorV3Interface.sol";

/**
 * @title MockAggregatorV3
 * @notice Mock Chainlink aggregator for testing Proof of Reserve feeds.
 * @dev Allows setting arbitrary round data to simulate various PoR scenarios.
 */
contract MockAggregatorV3 is AggregatorV3Interface {
    uint8 private _decimals;
    string private _description;
    uint256 private _version;

    int256 private _latestAnswer;
    uint80 private _latestRound;
    uint256 private _latestTimestamp;

    mapping(uint80 => int256) private _answers;
    mapping(uint80 => uint256) private _timestamps;

    constructor(uint8 decimals_, string memory description_) {
        _decimals = decimals_;
        _description = description_;
        _version = 1;
    }

    function setLatestRoundData(int256 answer, uint256 timestamp) external {
        _latestRound++;
        _latestAnswer = answer;
        _latestTimestamp = timestamp;
        _answers[_latestRound] = answer;
        _timestamps[_latestRound] = timestamp;
    }

    function setRoundData(uint80 roundId, int256 answer, uint256 timestamp) external {
        _answers[roundId] = answer;
        _timestamps[roundId] = timestamp;
        if (roundId > _latestRound) {
            _latestRound = roundId;
            _latestAnswer = answer;
            _latestTimestamp = timestamp;
        }
    }

    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    function description() external view override returns (string memory) {
        return _description;
    }

    function version() external view override returns (uint256) {
        return _version;
    }

    function getRoundData(uint80 _roundId)
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (_roundId, _answers[_roundId], _timestamps[_roundId], _timestamps[_roundId], _roundId);
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (_latestRound, _latestAnswer, _latestTimestamp, _latestTimestamp, _latestRound);
    }
}
