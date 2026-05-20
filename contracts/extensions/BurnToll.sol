// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../Stablecoin.sol";
import "../interfaces/IBurnTollFloorPool.sol";

/**
 * @title BurnToll
 * @notice Optional mint/redeem toll module that routes stablecoin tolls into a
 *         floor pool which buys and burns a paired governance token.
 * @dev Configuration is controlled by the existing Stablecoin admin role.
 */
contract BurnToll {
    using SafeERC20 for IERC20;

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant DEFAULT_MINT_TOLL_BPS = 50;
    uint256 public constant DEFAULT_REDEEM_TOLL_BPS = 50;

    /// @notice Stablecoin whose admin role controls this module.
    Stablecoin public immutable stablecoin;

    /// @notice Mint toll in basis points.
    uint256 public mintTollBps;
    /// @notice Redeem toll in basis points.
    uint256 public redeemTollBps;
    /// @notice Governance token bought and burned by the floor pool.
    address public burnTokenAddress;
    /// @notice Pool that receives stablecoin tolls.
    address public floorPoolAddress;
    /// @notice Minimum stablecoin-side depth required before tolls apply.
    uint256 public floorPoolMinDepth;

    /// @notice Addresses allowed to route already minted toll balances.
    mapping(address => bool) public tollOperators;

    event TollConfigUpdated(
        uint256 mintTollBps,
        uint256 redeemTollBps,
        address indexed burnTokenAddress,
        address indexed floorPoolAddress,
        uint256 floorPoolMinDepth
    );
    event TollOperatorSet(address indexed operator, bool authorized);
    event TollRouted(
        address indexed operator,
        bool indexed mintToll,
        uint256 stablecoinAmount,
        address indexed floorPoolAddress,
        address burnTokenAddress
    );

    error InvalidBps();
    error NotStablecoinAdmin(address account);
    error NotTollOperator(address account);
    error TollBalanceTooLow(uint256 available, uint256 required);
    error ZeroAddress();

    modifier onlyStablecoinAdmin() {
        if (!stablecoin.hasRole(stablecoin.DEFAULT_ADMIN_ROLE(), msg.sender)) {
            revert NotStablecoinAdmin(msg.sender);
        }
        _;
    }

    modifier onlyTollOperator() {
        if (!tollOperators[msg.sender]) {
            revert NotTollOperator(msg.sender);
        }
        _;
    }

    /**
     * @notice Creates a burn-toll module with the default 0.5% mint and redeem tolls.
     * @param stablecoin_ Stablecoin whose admin role controls this module.
     * @param burnTokenAddress_ Governance token bought and burned by the floor pool.
     * @param floorPoolAddress_ Pool that receives stablecoin tolls.
     * @param floorPoolMinDepth_ Minimum stablecoin-side depth required before tolls apply.
     */
    constructor(
        address stablecoin_,
        address burnTokenAddress_,
        address floorPoolAddress_,
        uint256 floorPoolMinDepth_
    ) {
        if (stablecoin_ == address(0)) revert ZeroAddress();
        stablecoin = Stablecoin(stablecoin_);
        _setTollConfig(
            DEFAULT_MINT_TOLL_BPS,
            DEFAULT_REDEEM_TOLL_BPS,
            burnTokenAddress_,
            floorPoolAddress_,
            floorPoolMinDepth_
        );
    }

    /**
     * @notice Updates toll rates, burn token, pool address, and minimum pool depth.
     * @param mintTollBps_ Mint toll in basis points.
     * @param redeemTollBps_ Redeem toll in basis points.
     * @param burnTokenAddress_ Governance token bought and burned by the floor pool.
     * @param floorPoolAddress_ Pool that receives stablecoin tolls.
     * @param floorPoolMinDepth_ Minimum stablecoin-side depth required before tolls apply.
     */
    function setTollConfig(
        uint256 mintTollBps_,
        uint256 redeemTollBps_,
        address burnTokenAddress_,
        address floorPoolAddress_,
        uint256 floorPoolMinDepth_
    ) external onlyStablecoinAdmin {
        _setTollConfig(
            mintTollBps_,
            redeemTollBps_,
            burnTokenAddress_,
            floorPoolAddress_,
            floorPoolMinDepth_
        );
    }

    /**
     * @notice Authorizes or revokes a gateway that may route toll balances.
     * @param operator Address allowed to call routeMintToll and routeRedeemToll.
     * @param authorized Whether the operator is authorized.
     */
    function setTollOperator(address operator, bool authorized) external onlyStablecoinAdmin {
        if (operator == address(0)) revert ZeroAddress();
        tollOperators[operator] = authorized;
        emit TollOperatorSet(operator, authorized);
    }

    /**
     * @notice Previews the mint toll for a gross mint amount.
     * @param stablecoinAmount Gross stablecoin amount being minted.
     * @return tollAmount Toll amount, or zero when disabled or skipped.
     * @return applies True when the toll should be applied.
     * @return poolDepth Current stablecoin-side pool depth.
     */
    function previewMintToll(
        uint256 stablecoinAmount
    ) external view returns (uint256 tollAmount, bool applies, uint256 poolDepth) {
        return _previewToll(stablecoinAmount, mintTollBps);
    }

    /**
     * @notice Previews the redeem toll for a gross redeem amount.
     * @param stablecoinAmount Gross stablecoin amount being redeemed.
     * @return tollAmount Toll amount, or zero when disabled or skipped.
     * @return applies True when the toll should be applied.
     * @return poolDepth Current stablecoin-side pool depth.
     */
    function previewRedeemToll(
        uint256 stablecoinAmount
    ) external view returns (uint256 tollAmount, bool applies, uint256 poolDepth) {
        return _previewToll(stablecoinAmount, redeemTollBps);
    }

    /**
     * @notice Routes a precomputed mint toll from this contract to the floor pool.
     * @param tollAmount Stablecoin amount already held by this contract.
     * @return routedAmount Amount sent to the floor pool.
     */
    function routeMintToll(uint256 tollAmount) external onlyTollOperator returns (uint256 routedAmount) {
        return _routeToll(tollAmount, true);
    }

    /**
     * @notice Routes a precomputed redeem toll from this contract to the floor pool.
     * @param tollAmount Stablecoin amount already held by this contract.
     * @return routedAmount Amount sent to the floor pool.
     */
    function routeRedeemToll(uint256 tollAmount) external onlyTollOperator returns (uint256 routedAmount) {
        return _routeToll(tollAmount, false);
    }

    function _setTollConfig(
        uint256 mintTollBps_,
        uint256 redeemTollBps_,
        address burnTokenAddress_,
        address floorPoolAddress_,
        uint256 floorPoolMinDepth_
    ) internal {
        if (mintTollBps_ > BPS_DENOMINATOR || redeemTollBps_ > BPS_DENOMINATOR) {
            revert InvalidBps();
        }
        if (mintTollBps_ > 0 || redeemTollBps_ > 0) {
            if (burnTokenAddress_ == address(0) || floorPoolAddress_ == address(0)) {
                revert ZeroAddress();
            }
        }

        mintTollBps = mintTollBps_;
        redeemTollBps = redeemTollBps_;
        burnTokenAddress = burnTokenAddress_;
        floorPoolAddress = floorPoolAddress_;
        floorPoolMinDepth = floorPoolMinDepth_;

        emit TollConfigUpdated(
            mintTollBps_,
            redeemTollBps_,
            burnTokenAddress_,
            floorPoolAddress_,
            floorPoolMinDepth_
        );
    }

    function _previewToll(
        uint256 stablecoinAmount,
        uint256 tollBps
    ) internal view returns (uint256 tollAmount, bool applies, uint256 poolDepth) {
        if (stablecoinAmount == 0 || tollBps == 0) {
            return (0, false, 0);
        }

        poolDepth = IBurnTollFloorPool(floorPoolAddress).stablecoinDepth(address(stablecoin));
        if (poolDepth < floorPoolMinDepth) {
            return (0, false, poolDepth);
        }

        tollAmount = (stablecoinAmount * tollBps) / BPS_DENOMINATOR;
        applies = tollAmount > 0;
    }

    function _routeToll(uint256 tollAmount, bool mintToll) internal returns (uint256 routedAmount) {
        if (tollAmount == 0) return 0;
        if (burnTokenAddress == address(0) || floorPoolAddress == address(0)) {
            revert ZeroAddress();
        }

        uint256 balance = IERC20(address(stablecoin)).balanceOf(address(this));
        if (balance < tollAmount) {
            revert TollBalanceTooLow(balance, tollAmount);
        }

        IERC20(address(stablecoin)).safeTransfer(floorPoolAddress, tollAmount);
        IBurnTollFloorPool(floorPoolAddress).buyAndBurn(burnTokenAddress, tollAmount);

        emit TollRouted(msg.sender, mintToll, tollAmount, floorPoolAddress, burnTokenAddress);
        return tollAmount;
    }
}
