// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface Vm {
    function expectRevert() external;
    function expectRevert(bytes memory revertData) external;
    function expectRevert(bytes4 selector) external;
    function prank(address msgSender) external;
    function startPrank(address msgSender) external;
    function stopPrank() external;
    function warp(uint256 newTimestamp) external;
}

abstract contract Test {
    struct FuzzSelector {
        address addr;
        bytes4[] selectors;
    }

    struct FuzzArtifactSelector {
        string artifact;
        bytes4[] selectors;
    }

    struct FuzzInterface {
        address addr;
        string[] artifacts;
    }

    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address[] private _targetedContracts;

    function targetContract(address target) internal virtual {
        _targetedContracts.push(target);
    }

    function targetContracts() public view returns (address[] memory) {
        return _targetedContracts;
    }

    function excludeArtifacts() public pure returns (string[] memory) {
        return new string[](0);
    }

    function excludeContracts() public pure returns (address[] memory) {
        return new address[](0);
    }

    function excludeSelectors() public pure returns (FuzzSelector[] memory) {
        return new FuzzSelector[](0);
    }

    function excludeSenders() public pure returns (address[] memory) {
        return new address[](0);
    }

    function targetArtifacts() public pure returns (string[] memory) {
        return new string[](0);
    }

    function targetArtifactSelectors() public pure returns (FuzzArtifactSelector[] memory) {
        return new FuzzArtifactSelector[](0);
    }

    function targetInterfaces() public pure returns (FuzzInterface[] memory) {
        return new FuzzInterface[](0);
    }

    function targetSelectors() public pure returns (FuzzSelector[] memory) {
        return new FuzzSelector[](0);
    }

    function targetSenders() public pure returns (address[] memory) {
        return new address[](0);
    }

    function bound(uint256 value, uint256 min, uint256 max) internal pure returns (uint256) {
        require(min <= max, "bound invalid range");
        uint256 size = max - min + 1;
        if (size == 0) {
            return value;
        }
        return min + (value % size);
    }

    function assertEq(uint256 actual, uint256 expected) internal pure {
        require(actual == expected, "assertEq(uint256)");
    }

    function assertEq(address actual, address expected) internal pure {
        require(actual == expected, "assertEq(address)");
    }

    function assertEq(string memory actual, string memory expected) internal pure {
        require(keccak256(bytes(actual)) == keccak256(bytes(expected)), "assertEq(string)");
    }

    function assertTrue(bool value) internal pure {
        require(value, "assertTrue");
    }

    function assertTrue(bool value, string memory reason) internal pure {
        require(value, reason);
    }

    function assertFalse(bool value) internal pure {
        require(!value, "assertFalse");
    }

    function assertFalse(bool value, string memory reason) internal pure {
        require(!value, reason);
    }
}
