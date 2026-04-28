// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";
import "../../contracts/Stablecoin.sol";

contract StablecoinHandler is Test {
    Stablecoin public immutable coin;
    address public immutable admin;

    uint256 public mintedTotal;
    uint256 public burnedTotal;

    address internal constant ACTOR_ONE = address(0x1001);
    address internal constant ACTOR_TWO = address(0x1002);
    address internal constant ACTOR_THREE = address(0x1003);
    address internal constant ACTOR_FOUR = address(0x1004);

    constructor(Stablecoin _coin, address _admin) {
        coin = _coin;
        admin = _admin;
    }

    function mint(uint256 actorSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        amount = bound(amount, 0, type(uint96).max);

        if (amount == 0) return;

        vm.prank(admin);
        coin.mint(actor, amount);
        mintedTotal += amount;
    }

    function burn(uint256 actorSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        uint256 balance = coin.balanceOf(actor);

        if (balance == 0) return;

        amount = bound(amount, 1, balance);

        vm.prank(actor);
        coin.burn(amount);
        burnedTotal += amount;
    }

    function expectedSupply() external view returns (uint256) {
        return mintedTotal - burnedTotal;
    }

    function _actor(uint256 seed) internal pure returns (address) {
        uint256 slot = seed % 4;
        if (slot == 0) return ACTOR_ONE;
        if (slot == 1) return ACTOR_TWO;
        if (slot == 2) return ACTOR_THREE;
        return ACTOR_FOUR;
    }
}

contract StablecoinInvariants is StdInvariant, Test {
    Stablecoin internal coin;
    StablecoinHandler internal handler;
    address internal admin = address(this);

    function setUp() public {
        coin = new Stablecoin("Invariant Stablecoin", "iUSD", admin);
        handler = new StablecoinHandler(coin, admin);
        targetContract(address(handler));
    }

    function invariant_totalSupplyMatchesNetMints() public view {
        assertEq(coin.totalSupply(), handler.expectedSupply(), "total supply drifted from net mint-burn accounting");
    }
}
