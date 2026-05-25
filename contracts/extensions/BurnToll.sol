// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../Stablecoin.sol";

contract BurnToll is AccessControl {
    using SafeERC20 for IERC20;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    Stablecoin public stablecoin;
    IERC20 public burnToken;
    address public floorPoolAddress;

    uint256 public mintTollBps;
    uint256 public redeemTollBps;
    uint256 public floorPoolMinDepth;

    event TollCollected(address indexed user, uint256 mintAmount, uint256 tollAmount);
    event RedeemTollCollected(address indexed user, uint256 redeemAmount, uint256 tollAmount);
    event ParametersUpdated(uint256 mintTollBps, uint256 redeemTollBps, uint256 minDepth);
    event BurnTokenUpdated(address indexed token);
    event FloorPoolUpdated(address indexed pool);

    error ZeroAddress();
    error InvalidBps();
    error PoolTooShallow(uint256 depth, uint256 minDepth);

    constructor(
        address _stablecoin,
        address _burnToken,
        address _floorPoolAddress,
        address _admin,
        uint256 _mintTollBps,
        uint256 _redeemTollBps,
        uint256 _floorPoolMinDepth
    ) {
        if (_stablecoin == address(0) || _admin == address(0)) revert ZeroAddress();
        if (_mintTollBps > 1000 || _redeemTollBps > 1000) revert InvalidBps();

        stablecoin = Stablecoin(_stablecoin);
        burnToken = IERC20(_burnToken);
        floorPoolAddress = _floorPoolAddress;
        mintTollBps = _mintTollBps;
        redeemTollBps = _redeemTollBps;
        floorPoolMinDepth = _floorPoolMinDepth;

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
    }

    function setBurnToken(address _token) external onlyRole(ADMIN_ROLE) {
        if (_token == address(0)) revert ZeroAddress();
        burnToken = IERC20(_token);
        emit BurnTokenUpdated(_token);
    }

    function setFloorPool(address _pool) external onlyRole(ADMIN_ROLE) {
        if (_pool == address(0)) revert ZeroAddress();
        floorPoolAddress = _pool;
        emit FloorPoolUpdated(_pool);
    }

    function setParameters(
        uint256 _mintTollBps,
        uint256 _redeemTollBps,
        uint256 _minDepth
    ) external onlyRole(ADMIN_ROLE) {
        if (_mintTollBps > 1000 || _redeemTollBps > 1000) revert InvalidBps();
        mintTollBps = _mintTollBps;
        redeemTollBps = _redeemTollBps;
        floorPoolMinDepth = _minDepth;
        emit ParametersUpdated(_mintTollBps, _redeemTollBps, _minDepth);
    }

    function applyMintToll(address user, uint256 amount) external returns (uint256 netAmount) {
        if (msg.sender != address(stablecoin) && msg.sender != address(0)) {
            revert("Unauthorized");
        }
        if (mintTollBps == 0) return amount;

        uint256 toll = (amount * mintTollBps) / 10000;
        netAmount = amount - toll;

        if (toll > 0) {
            _swapAndBurn(toll);
            emit TollCollected(user, amount, toll);
        }
    }

    function applyRedeemToll(address user, uint256 amount) external returns (uint256 netAmount) {
        if (mintTollBps == 0) return amount;

        uint256 toll = (amount * redeemTollBps) / 10000;
        netAmount = amount - toll;

        if (toll > 0) {
            _swapAndBurn(toll);
            emit RedeemTollCollected(user, amount, toll);
        }
    }

    function _swapAndBurn(uint256 amount) internal {
        if (floorPoolMinDepth > 0) {
            uint256 poolDepth = _getPoolDepth();
            if (poolDepth < floorPoolMinDepth) {
                revert PoolTooShallow(poolDepth, floorPoolMinDepth);
            }
        }
        stablecoin.approve(floorPoolAddress, amount);
        (bool success,) = floorPoolAddress.call(
            abi.encodeWithSignature("swap(address,uint256,address)", address(stablecoin), amount, address(burnToken))
        );
        if (success) {
            uint256 burnBalance = burnToken.balanceOf(address(this));
            if (burnBalance > 0) {
                burnToken.safeTransfer(address(0xdead), burnBalance);
            }
        }
    }

    function _getPoolDepth() internal view returns (uint256) {
        (bool success, bytes memory data) = floorPoolAddress.staticcall(
            abi.encodeWithSignature("getReserves()")
        );
        if (!success || data.length < 32) return 0;
        return abi.decode(data, (uint256));
    }
}
