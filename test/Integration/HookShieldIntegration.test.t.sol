// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";

import {HookShield} from "../../src/HookShield.sol";

contract HookShieldIntegrationTest is Test {
    PoolManager poolManager;
    HookShield hook;

    MockERC20 token0;
    MockERC20 token1;
    address user = address(0xBEEF);
    uint160 permissions =Hooks.BEFORE_SWAP_FLAG |Hooks.AFTER_SWAP_FLAG;
    function setUp() public {
        poolManager = new PoolManager(address(this));

        token0 = new MockERC20();
        token1 = new MockERC20();

        token0.mint(user, 1e24);
        token1.mint(user, 1e24);
      
        hook =  HookShield(_deployHook());
         require(
        Hooks.isValidHookAddress(IHooks(address(hook)), 0),
        "INVALID_HOOK"
    );
    
    }
    function _deployHook() internal returns (HookShield hookAddr){
       bytes memory constructorArgs = abi.encode(
        address(this),
        address(this)
    );

    (address hookAddress, bytes32 salt) = HookMiner.find(
        address(this),
        permissions,
        type(HookShield).creationCode,
        constructorArgs
    );

    // deploy using Foundry-style direct CREATE2 via vm
    address addr = address(new HookShield{salt: salt}(address(this), address(this)));

    require(addr == hookAddress, "MISMATCH");

    hookAddr = HookShield(addr);   
    }

    function test_init_pool() public {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000, // uint24 ONLY
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        poolManager.initialize(key, 79228162514264337593543950336);

        assertTrue(true);
    }
}


/* ---------------- MOCKS ---------------- */

contract MarketDataMock {
    function getLatestMarketData()
        external
        pure
        returns (int256 price, int256 vol, int256, int256)
    {
        return (2000e18, 50e18, 0, 0);
    }
}

contract FeeCalculatorMock {
    function calculateFee(uint256 tradeSize, uint256 volatility)
        external
        pure
        returns (uint24)
    {
        return uint24((tradeSize / 1e15 + volatility) % 5000);
    }
}

contract MockERC20 {
    string public name = "Mock";
    string public symbol = "MCK";
    uint8 public decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}