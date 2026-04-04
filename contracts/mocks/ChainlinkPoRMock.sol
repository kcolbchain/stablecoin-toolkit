// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../interfaces/IAggregatorV3.sol";

/**
 * @title ChainlinkPoRMock
 * @notice Mock aggregator that simulates Chainlink Proof of Reserves feed responses.
 * @dev For testing purposes only. DO NOT use in production.
 */
contract ChainlinkPoRMock is AggregatorV3Interface {
    string private _description = "Mock PoR Feed";
    uint8 private _decimals = 8;
    uint256 private _version = 1;

    struct RoundData {
        uint80 roundId;
        int256 answer;
        uint256 startedAt;
        uint256 updatedAt;
        uint80 answeredInRound;
    }

    RoundData[] private _roundHistory;
    int256 private _currentAnswer;
    uint80 private _currentRoundId;
    uint256 private _currentUpdatedAt;

    event AnswerUpdated(int256 indexed current, uint256 indexed roundId, uint256 updatedAt);

    constructor(int256 initialAnswer) {
        _currentAnswer = initialAnswer;
        _currentRoundId = 1;
        _currentUpdatedAt = block.timestamp;
        _roundHistory.push(RoundData({
            roundId: 1,
            answer: initialAnswer,
            startedAt: block.timestamp,
            updatedAt: block.timestamp,
            answeredInRound: 1
        }));
    }

    function setAnswer(int256 newAnswer) external {
        _currentAnswer = newAnswer;
        _currentRoundId++;
        _currentUpdatedAt = block.timestamp;
        _roundHistory.push(RoundData({
            roundId: _currentRoundId,
            answer: newAnswer,
            startedAt: block.timestamp,
            updatedAt: block.timestamp,
            answeredInRound: _currentRoundId
        }));
        emit AnswerUpdated(newAnswer, _currentRoundId, block.timestamp);
    }

    function setAnswerWithTimestamp(int256 newAnswer, uint256 timestamp) external {
        _currentAnswer = newAnswer;
        _currentRoundId++;
        _currentUpdatedAt = timestamp;
        _roundHistory.push(RoundData({
            roundId: _currentRoundId,
            answer: newAnswer,
            startedAt: timestamp,
            updatedAt: timestamp,
            answeredInRound: _currentRoundId
        }));
        emit AnswerUpdated(newAnswer, _currentRoundId, timestamp);
    }

    function description() external view override returns (string memory) {
        return _description;
    }

    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    function version() external view override returns (uint256) {
        return _version;
    }

    function getRoundData(uint80 _roundId) external view override returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    ) {
        require(_roundId > 0 && _roundId <= _currentRoundId, "Round not found");
        RoundData storage round = _roundHistory[_roundId - 1];
        return (
            round.roundId,
            round.answer,
            round.startedAt,
            round.updatedAt,
            round.answeredInRound
        );
    }

    function latestRoundData() external view override returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    ) {
        RoundData storage round = _roundHistory[_roundHistory.length - 1];
        return (
            round.roundId,
            round.answer,
            round.startedAt,
            round.updatedAt,
            round.answeredInRound
        );
    }

}
