// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {HookShield} from "../../src/HookShield.sol";

contract HookShieldIntegrationTest is Test {
    PoolManager poolManager;
    HookShield hook;
    MarketDataMock market;
    FeeCalculatorMock feeCalc;

    MockERC20 tokenA;
    MockERC20 tokenB;
    MockERC20 token0;
    MockERC20 token1;

    address user = address(0xBEEF);
    uint160 constant permissions = uint160(Hooks.BEFORE_SWAP_FLAG);

    function setUp() public {
        poolManager = new PoolManager(address(this));
        market = new MarketDataMock();
        feeCalc = new FeeCalculatorMock();

        tokenA = new MockERC20();
        tokenB = new MockERC20();
        if (address(tokenA) < address(tokenB)) {
            token0 = tokenA;
            token1 = tokenB;
        } else {
            token0 = tokenB;
            token1 = tokenA;
        }

        token0.mint(user, 1e24);
        token1.mint(user, 1e24);

        hook = _deployHook();
        Hooks.validateHookPermissions(
            IHooks(address(hook)),
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            })
        );

        vm.startPrank(user);
        token0.approve(address(poolManager), type(uint256).max);
        token1.approve(address(poolManager), type(uint256).max);
        vm.stopPrank();
    }

    function _deployHook() internal returns (HookShield hookAddr) {
        bytes memory constructorArgs = abi.encode(address(market), address(feeCalc), address(poolManager));

        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), permissions, type(HookShield).creationCode, constructorArgs);

        require(hookAddress != address(0), "HookMiner failed");
        hookAddr = new HookShield{salt: salt}(address(market), address(feeCalc), IPoolManager(address(poolManager)));

        require(address(hookAddr) == hookAddress, "HOOK_ADDRESS_MISMATCH");
    }

    function test_init_pool() public {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        poolManager.initialize(key, 79228162514264337593543950336);

        assertTrue(true);
    }
}

/* ---------------- MOCKS ---------------- */

contract MarketDataMock {
    function getLatestMarketData() external view returns (int256 price, int256 vol, int256, int256 updatedAt) {
        return (2000e18, 50e18, 0, int256(block.timestamp));
    }
}

contract FeeCalculatorMock {
    function calculateFee(uint256 tradeSize, uint256 volatility) external pure returns (uint24) {
        return uint24((tradeSize / 1e15 + volatility) % 5000);
    }
}

contract MockERC20 {
    string public name = "Mock";
    string public symbol = "MCK";
    uint8 public decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}
