// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../contracts/Stablecoin.sol";

contract StablecoinSupplyHandler is Test {
    uint256 internal constant MAX_ACTION_AMOUNT = type(uint96).max;

    Stablecoin public immutable coin;
    address public immutable admin;
    address[] internal actors;

    uint256 public sumMints;
    uint256 public sumBurns;

    constructor(Stablecoin coin_, address admin_) {
        coin = coin_;
        admin = admin_;

        actors.push(address(0x1001));
        actors.push(address(0x1002));
        actors.push(address(0x1003));
        actors.push(address(0x1004));
    }

    function mint(uint256 actorSeed, uint256 amount) public {
        address actor = actors[actorSeed % actors.length];
        amount = bound(amount, 0, MAX_ACTION_AMOUNT);

        vm.prank(admin);
        coin.mint(actor, amount);

        sumMints += amount;
    }

    function burn(uint256 actorSeed, uint256 amount) public {
        address actor = actors[actorSeed % actors.length];
        uint256 balance = coin.balanceOf(actor);
        amount = bound(amount, 0, balance);

        vm.prank(actor);
        coin.burn(amount);

        sumBurns += amount;
    }
}

contract StablecoinInvariants is Test {
    Stablecoin public coin;
    StablecoinSupplyHandler public handler;
    address public admin = address(1);

    function setUp() public {
        vm.prank(admin);
        coin = new Stablecoin("Test Stablecoin", "TSTBL", admin);

        handler = new StablecoinSupplyHandler(coin, admin);
        targetContract(address(handler));
    }

    function invariant_totalSupplyMatchesNetMints() public view {
        assertEq(coin.totalSupply(), handler.sumMints() - handler.sumBurns());
    }
}
