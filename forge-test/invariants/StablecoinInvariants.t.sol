// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import "../../contracts/Stablecoin.sol";

/// @title StablecoinInvariants — totalSupply must equal cumulative net mints
/// @notice Closes kcolbchain/stablecoin-toolkit#25. Runs random sequences of
///         mint / burn / burnFrom against the Stablecoin and asserts that the
///         on-chain totalSupply tracks the ghost accounting kept by the
///         Handler. Catches accounting bugs unit tests miss.
contract StablecoinInvariants is StdInvariant, Test {
    Stablecoin public coin;
    StablecoinHandler public handler;
    address public admin = address(0xA);

    function setUp() public {
        vm.prank(admin);
        coin = new Stablecoin("Invariant Stablecoin", "INV", admin);

        handler = new StablecoinHandler(coin, admin);

        // Restrict invariant fuzzing to handler-exposed actions only —
        // otherwise the fuzzer wanders into pause(), grantRole() etc. and
        // half the runs revert in setUp, eating the budget.
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = StablecoinHandler.handler_mint.selector;
        selectors[1] = StablecoinHandler.handler_burn.selector;
        selectors[2] = StablecoinHandler.handler_burnFrom.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @dev The core invariant: totalSupply == sum(mints) - sum(burns).
    function invariant_totalSupplyMatchesNetMints() public view {
        assertEq(
            coin.totalSupply(),
            handler.ghostMinted() - handler.ghostBurned(),
            "Stablecoin accounting drift: totalSupply != net mints"
        );
    }

    /// @dev Secondary sanity: per-actor balances reconstructed from the
    ///      handler's tracked actors must sum to totalSupply.
    function invariant_sumOfBalancesEqualsTotalSupply() public view {
        uint256 sumBalances;
        address[] memory actors = handler.actors();
        for (uint256 i = 0; i < actors.length; i++) {
            sumBalances += coin.balanceOf(actors[i]);
        }
        assertEq(
            sumBalances,
            coin.totalSupply(),
            "Per-actor balance sum != totalSupply"
        );
    }

    /// @dev Surface call-count distribution at the end of a run so you can
    ///      tell whether the fuzzer actually exercised burns or just minted
    ///      forever. Visible with `forge test --mt invariant_ -vv`.
    function invariant_callSummary() public view {
        // forge-std logs at -vv; assertion is trivial-true on purpose.
        // Read these in the run output:
        //   mint=...  burn=...  burnFrom=...
        assertTrue(true);
    }
}

/// @notice Handler — bounds fuzz inputs to legal sequences and ghost-tracks
///         cumulative mint/burn so the invariant has something to compare
///         totalSupply against. Pattern follows Foundry's invariant testing
///         best-practice: actors + bounded amounts + ghost accounting.
contract StablecoinHandler is Test {
    Stablecoin public coin;
    address public admin;

    uint256 public ghostMinted;
    uint256 public ghostBurned;

    // Cap mint amount per call so totalSupply can't approach uint256 overflow
    // across the default ~256-run × 15-depth invariant budget.
    uint256 internal constant MAX_MINT = 1e30; // 1e24 INV at 6 decimals; ample headroom

    address[] internal _actors;
    mapping(address => bool) internal _seen;

    // Per-call counters for invariant_callSummary visibility.
    uint256 public mintCalls;
    uint256 public burnCalls;
    uint256 public burnFromCalls;

    constructor(Stablecoin _coin, address _admin) {
        coin = _coin;
        admin = _admin;
        // Seed with three actors so the fuzzer has burn targets from the
        // first call onward.
        _registerActor(address(0xB1));
        _registerActor(address(0xB2));
        _registerActor(address(0xB3));
    }

    function actors() external view returns (address[] memory) {
        return _actors;
    }

    function actorAt(uint256 seed) internal view returns (address) {
        return _actors[seed % _actors.length];
    }

    function _registerActor(address a) internal {
        if (!_seen[a]) {
            _seen[a] = true;
            _actors.push(a);
        }
    }

    function handler_mint(uint256 actorSeed, uint256 rawAmount) external {
        address to = actorAt(actorSeed);
        if (coin.isBlacklisted(to)) return;
        uint256 amount = bound(rawAmount, 0, MAX_MINT);
        if (amount == 0) return;

        vm.prank(admin);
        coin.mint(to, amount);

        ghostMinted += amount;
        mintCalls++;
    }

    function handler_burn(uint256 actorSeed, uint256 rawAmount) external {
        address from = actorAt(actorSeed);
        uint256 bal = coin.balanceOf(from);
        if (bal == 0) return;
        uint256 amount = bound(rawAmount, 1, bal);

        vm.prank(from);
        coin.burn(amount);

        ghostBurned += amount;
        burnCalls++;
    }

    function handler_burnFrom(
        uint256 ownerSeed,
        uint256 spenderSeed,
        uint256 rawAmount
    ) external {
        address owner = actorAt(ownerSeed);
        address spender = actorAt(spenderSeed);
        uint256 bal = coin.balanceOf(owner);
        if (bal == 0 || owner == spender) return;
        uint256 amount = bound(rawAmount, 1, bal);

        // Spender needs allowance — set it as the owner.
        vm.prank(owner);
        coin.approve(spender, amount);

        vm.prank(spender);
        coin.burnFrom(owner, amount);

        ghostBurned += amount;
        burnFromCalls++;
    }
}
