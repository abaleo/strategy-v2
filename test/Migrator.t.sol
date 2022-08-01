// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.13;
import "forge-std/Test.sol";
import "../contracts/Strategy.sol";
import "../contracts/draft/Migrator.sol";
import "../contracts/draft/Exchange.sol";
import "../contracts/mocks/FYTokenMock.sol";
import "@yield-protocol/yieldspace-tv/src/interfaces/IPool.sol";
import "@yield-protocol/yieldspace-tv/src/Pool/Modules/PoolNonTv.sol";
import "@yield-protocol/yieldspace-tv/src/Pool/PoolErrors.sol";
import "@yield-protocol/yieldspace-tv/src/YieldMath.sol";
import "@yield-protocol/yieldspace-tv/src/YieldMathExtensions.sol";
import "@yield-protocol/yieldspace-tv/src/test/mocks/ERC4626TokenMock.sol";
import "@yield-protocol/vault-v2/contracts/FYToken.sol";
import "@yield-protocol/vault-v2/contracts/interfaces/DataTypes.sol";
import "@yield-protocol/vault-v2/contracts/interfaces/ILadle.sol";
import "@yield-protocol/vault-v2/contracts/interfaces/IJoin.sol";
import "@yield-protocol/vault-v2/contracts/interfaces/IOracle.sol";
import "@yield-protocol/utils-v2/contracts/token/SafeERC20Namer.sol";
import "@yield-protocol/utils-v2/contracts/token/IERC20Metadata.sol";
import "@yield-protocol/utils-v2/contracts/access/AccessControl.sol";

interface ICauldronAddSeries {
    function addSeries(bytes6, bytes6, IFYToken) external;
}

abstract contract ZeroState is Test {
    using stdStorage for StdStorage;

    // YSDAI6MMS: 0x7ACFe277dEd15CabA6a8Da2972b1eb93fe1e2cCD
    // YSDAI6MJD: 0x1144e14E9B0AA9e181342c7e6E0a9BaDB4ceD295
    // YSUSDC6MMS: 0xFBc322415CBC532b54749E31979a803009516b5D
    // YSUSDC6MJD: 0x8e8D6aB093905C400D583EfD37fbeEB1ee1c0c39
    // YSETH6MMS: 0xcf30A5A994f9aCe5832e30C138C9697cda5E1247
    // YSETH6MJD: 0x831dF23f7278575BA0b136296a285600cD75d076
    // YSFRAX6MMS: 0x1565F539E96c4d440c38979dbc86Fd711C995DD6
    // YSFRAX6MJD: 0x47cC34188A2869dAA1cE821C8758AA8442715831

    address timelock = 0x3b870db67a45611CF4723d44487EAF398fAc51E3;
    IStrategy srcStrategy = IStrategy(0x1144e14E9B0AA9e181342c7e6E0a9BaDB4ceD295);
    Strategy dstStrategy;
    uint32 srcMaturity;
    uint32 dstMaturity;
    IFYToken dstFYToken;
    bytes6 dstSeriesId;
    IPool srcPool;
    Pool dstPool;
    IERC20Metadata sharesToken;
    IERC20Metadata baseToken;
    bytes6 baseId;
    IJoin baseJoin;
    ICauldron cauldron;
    Exchange exchange;
    Migrator migrator;

    function setUp() public virtual {
        vm.createSelectFork('tenderly');
        vm.startPrank(timelock);

        srcMaturity = uint32(srcStrategy.fyToken().maturity());
        dstMaturity = srcMaturity + (3 * 30 * 24 * 60 * 60);
        baseId = srcStrategy.baseId();
        baseJoin = IJoin(srcStrategy.baseJoin());
        srcPool = srcStrategy.pool();
        cauldron = srcStrategy.cauldron();

        baseToken = srcPool.baseToken();
        sharesToken = srcPool.sharesToken();
        (,,, uint16 g1Fee) = srcPool.getCache();

        dstFYToken = new FYToken(baseId, IOracle(address(0)), baseJoin, dstMaturity, "", "");
        AccessControl(address(baseJoin)).grantRole(
            bytes4(baseJoin.join.selector),
            address(dstFYToken)
        );
        AccessControl(address(baseJoin)).grantRole(
            bytes4(baseJoin.exit.selector),
            address(dstFYToken)
        );
        
        dstPool = new PoolNonTv(address(baseToken), address(dstFYToken), srcPool.ts(), g1Fee);
        AccessControl(address(dstPool)).grantRole(
            bytes4(dstPool.init.selector),
            address(timelock)
        );

        dstStrategy = new Strategy("", "", srcStrategy.ladle(), baseToken, baseId, address(baseJoin));
        AccessControl(address(dstStrategy)).grantRole(
            bytes4(dstStrategy.setNextPool.selector),
            address(timelock)
        );
        AccessControl(address(dstStrategy)).grantRole(
            bytes4(dstStrategy.startPool.selector),
            address(timelock)
        );
        
        migrator = new Migrator(cauldron);
        AccessControl(address(migrator)).grantRole(
            bytes4(migrator.prepare.selector),
            address(timelock)
        );
        AccessControl(address(migrator)).grantRole(
            bytes4(migrator.mint.selector),
            address(srcStrategy)
        );

        exchange = new Exchange();
        AccessControl(address(exchange)).grantRole(
            bytes4(exchange.register.selector),
            address(migrator)
        );

        vm.label(address(srcStrategy), "srcStrategy");
        vm.label(address(dstStrategy), "dstStrategy");
        vm.label(address(dstFYToken), "dstFYToken");
        vm.label(address(srcPool), "srcPool");
        vm.label(address(dstPool), "dstPool");
        vm.label(address(sharesToken), "sharesToken");
        vm.label(address(baseToken), "baseToken");
        vm.label(address(baseJoin), "baseJoin");
        vm.label(address(cauldron), "cauldron");
        vm.label(address(exchange), "exchange");
        vm.label(address(migrator), "migrator");

        // Warp to maturity of srcStrategy
        vm.warp(srcMaturity + 1);

        // srcStrategy divests
        srcStrategy.endPool();

        // Add dst series
        dstSeriesId = bytes6(uint48(srcStrategy.seriesId()) + 1);
        ICauldronAddSeries(address(cauldron)).addSeries(dstSeriesId, srcStrategy.baseId(), dstFYToken);

        // Init migrator
        stdstore
            .target(address(baseToken))
            .sig(baseToken.balanceOf.selector)
            .with_key(address(migrator))
            .checked_write(1);

        // Init dstPool
        stdstore
            .target(address(baseToken))
            .sig(baseToken.balanceOf.selector)
            .with_key(address(dstPool))
            .checked_write(100 * 10**baseToken.decimals());
        dstPool.init(address(0));

        // Init dstStrategy
        dstStrategy.setNextPool(dstPool, dstSeriesId);
        stdstore
            .target(address(baseToken))
            .sig(baseToken.balanceOf.selector)
            .with_key(address(dstStrategy))
            .checked_write(100 * 10**baseToken.decimals());
        dstStrategy.startPool(0, type(uint256).max);

        vm.stopPrank();
    }
}

contract PrepareTest is ZeroState {
    function testPrepare() public {
        console2.log("migrator.prepare(dstStrategy)");
        vm.startPrank(timelock);
        migrator.prepare(IStrategy(address(dstStrategy)));
        vm.stopPrank();
    }
}

abstract contract PrepareState is ZeroState {
    function setUp() public override virtual {
        super.setUp();
        vm.startPrank(timelock);
        migrator.prepare(IStrategy(address(dstStrategy)));
        vm.stopPrank();
    }
}

contract SetNextPoolTest is PrepareState {
    function testSetNextPool() public {
        console2.log("srcStrategy.setNextPool(IPool(address(migrator)), dstStrategy.seriesId())");
        vm.startPrank(timelock);
        srcStrategy.setNextPool(IPool(address(migrator)), dstStrategy.seriesId());
        vm.stopPrank();
    }
}

abstract contract SetNextPoolState is PrepareState {
    function setUp() public override virtual {
        super.setUp();
        vm.startPrank(timelock);
        srcStrategy.setNextPool(IPool(address(migrator)), dstStrategy.seriesId());
        vm.stopPrank();
    }
}

contract StartPoolTest is SetNextPoolState {
    function testStartPool() public {
        console2.log("srcStrategy.startPool(dstStrategy, exchange)");
        vm.startPrank(timelock);
        srcStrategy.startPool(
            uint256(bytes32(bytes20(address(dstStrategy)))),
            uint256(bytes32(bytes20(address(exchange))))
        );
        vm.stopPrank();
    }
}