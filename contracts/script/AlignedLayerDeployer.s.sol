// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

import "@eigenlayer/contracts/permissions/PauserRegistry.sol";
import {IDelegationManager} from "@eigenlayer/contracts/interfaces/IDelegationManager.sol";
import {IStrategyManager, IStrategy} from "@eigenlayer/contracts/interfaces/IStrategyManager.sol";
import {ISlasher} from "@eigenlayer/contracts/interfaces/ISlasher.sol";
import {StrategyBaseTVLLimits} from "@eigenlayer/contracts/strategies/StrategyBaseTVLLimits.sol";
import "@eigenlayer/test/mocks/EmptyContract.sol";

import {BLSPublicKeyCompendium} from "@eigenlayer-middleware/src/BLSPublicKeyCompendium.sol";
import "@eigenlayer-middleware/src/BLSRegistryCoordinatorWithIndices.sol" as blsregcoord;
import {BLSPubkeyRegistry, IBLSPubkeyRegistry} from "@eigenlayer-middleware/src/BLSPubkeyRegistry.sol";
import {IndexRegistry, IIndexRegistry} from "@eigenlayer-middleware/src/IndexRegistry.sol";
import {StakeRegistry, IStakeRegistry} from "@eigenlayer-middleware/src/StakeRegistry.sol";
import {IVoteWeigher} from "@eigenlayer-middleware/src/interfaces/IVoteWeigher.sol";

import {AlignedLayerServiceManager, IServiceManager} from "../src/AlignedLayerServiceManager.sol";
import {AlignedLayerTaskManager} from "../src/AlignedLayerTaskManager.sol";
import {IAlignedLayerTaskManager} from "../src/IAlignedLayerTaskManager.sol";
import "../src/ERC20Mock.sol";

import {Utils} from "./utils/Utils.sol";

import "forge-std/Test.sol";
import "forge-std/Script.sol";
import "forge-std/StdJson.sol";
import "forge-std/console.sol";

// # To deploy and verify our contract
// forge script script/CredibleAlignedLayerDeployer.s.sol:CredibleAlignedLayerDeployer --rpc-url $RPC_URL  --private-key $PRIVATE_KEY --broadcast -vvvv
contract CredibleAlignedLayerDeployer is Script, Utils {
    // DEPLOYMENT CONSTANTS
    uint256 public constant QUORUM_THRESHOLD_PERCENTAGE = 100;
    uint32 public constant TASK_RESPONSE_WINDOW_BLOCK = 30;
    uint32 public constant TASK_DURATION_BLOCKS = 0;
    // TODO: right now hardcoding these (this address is anvil's default address 9)
    address public constant AGGREGATOR_ADDR =
        0xa0Ee7A142d267C1f36714E4a8F75612F20a79720;
    address public constant TASK_GENERATOR_ADDR =
        0xa0Ee7A142d267C1f36714E4a8F75612F20a79720;

    // ERC20 and Strategy: we need to deploy this erc20, create a strategy for it, and whitelist this strategy in the strategymanager

    ERC20Mock public erc20Mock;
    StrategyBaseTVLLimits public erc20MockStrategy;

    // Credible AlignedLayer contracts
    ProxyAdmin public credibleAlignedLayerProxyAdmin;
    PauserRegistry public credibleAlignedLayerPauserReg;

    blsregcoord.BLSRegistryCoordinatorWithIndices public registryCoordinator;
    blsregcoord.IBLSRegistryCoordinatorWithIndices
        public registryCoordinatorImplementation;

    IBLSPubkeyRegistry public blsPubkeyRegistry;
    IBLSPubkeyRegistry public blsPubkeyRegistryImplementation;

    IIndexRegistry public indexRegistry;
    IIndexRegistry public indexRegistryImplementation;

    IStakeRegistry public stakeRegistry;
    IStakeRegistry public stakeRegistryImplementation;

    AlignedLayerServiceManager public credibleAlignedLayerServiceManager;
    IServiceManager public credibleAlignedLayerServiceManagerImplementation;

    AlignedLayerTaskManager public credibleAlignedLayerTaskManager;
    IAlignedLayerTaskManager
        public credibleAlignedLayerTaskManagerImplementation;

    function run() external {
        // Eigenlayer contracts
        string memory eigenlayerDeployedContracts = readOutput(
            "eigenlayer_deployment_output"
        );
        string memory sharedAvsDeployedContracts = readOutput(
            "shared_avs_contracts_deployment_output"
        );
        IStrategyManager strategyManager = IStrategyManager(
            stdJson.readAddress(
                eigenlayerDeployedContracts,
                ".addresses.strategyManager"
            )
        );
        IDelegationManager delegationManager = IDelegationManager(
            stdJson.readAddress(
                eigenlayerDeployedContracts,
                ".addresses.delegation"
            )
        );
        ISlasher slasher = ISlasher(
            stdJson.readAddress(
                eigenlayerDeployedContracts,
                ".addresses.slasher"
            )
        );
        ProxyAdmin eigenLayerProxyAdmin = ProxyAdmin(
            stdJson.readAddress(
                eigenlayerDeployedContracts,
                ".addresses.eigenLayerProxyAdmin"
            )
        );
        PauserRegistry eigenLayerPauserReg = PauserRegistry(
            stdJson.readAddress(
                eigenlayerDeployedContracts,
                ".addresses.eigenLayerPauserReg"
            )
        );
        BLSPublicKeyCompendium pubkeyCompendium = BLSPublicKeyCompendium(
            stdJson.readAddress(
                sharedAvsDeployedContracts,
                ".blsPublicKeyCompendium"
            )
        );
        StrategyBaseTVLLimits baseStrategyImplementation = StrategyBaseTVLLimits(
                stdJson.readAddress(
                    eigenlayerDeployedContracts,
                    ".addresses.baseStrategyImplementation"
                )
            );

        address credibleAlignedLayerCommunityMultisig = msg.sender;
        address credibleAlignedLayerPauser = msg.sender;

        vm.startBroadcast();
        _deployErc20AndStrategyAndWhitelistStrategy(
            eigenLayerProxyAdmin,
            eigenLayerPauserReg,
            baseStrategyImplementation,
            strategyManager
        );
        _deployCredibleAlignedLayerContracts(
            strategyManager,
            delegationManager,
            slasher,
            erc20MockStrategy,
            pubkeyCompendium,
            credibleAlignedLayerCommunityMultisig,
            credibleAlignedLayerPauser
        );
        vm.stopBroadcast();
    }

    function _deployErc20AndStrategyAndWhitelistStrategy(
        ProxyAdmin eigenLayerProxyAdmin,
        PauserRegistry eigenLayerPauserReg,
        StrategyBaseTVLLimits baseStrategyImplementation,
        IStrategyManager strategyManager
    ) internal {
        erc20Mock = new ERC20Mock();
        // TODO(samlaf): any reason why we are using the strategybase with tvl limits instead of just using strategybase?
        // the maxPerDeposit and maxDeposits below are just arbitrary values.
        erc20MockStrategy = StrategyBaseTVLLimits(
            address(
                new TransparentUpgradeableProxy(
                    address(baseStrategyImplementation),
                    address(eigenLayerProxyAdmin),
                    abi.encodeWithSelector(
                        StrategyBaseTVLLimits.initialize.selector,
                        1 ether, // maxPerDeposit
                        100 ether, // maxDeposits
                        IERC20(erc20Mock),
                        eigenLayerPauserReg
                    )
                )
            )
        );
        IStrategy[] memory strats = new IStrategy[](1);
        strats[0] = erc20MockStrategy;
        strategyManager.addStrategiesToDepositWhitelist(strats);
    }

    function _deployCredibleAlignedLayerContracts(
        IStrategyManager strategyManager,
        IDelegationManager delegationManager,
        ISlasher slasher,
        IStrategy strat,
        BLSPublicKeyCompendium pubkeyCompendium,
        address credibleAlignedLayerCommunityMultisig,
        address credibleAlignedLayerPauser
    ) internal {
        // Adding this as a temporary fix to make the rest of the script work with a single strategy
        // since it was originally written to work with an array of strategies
        IStrategy[1] memory deployedStrategyArray = [strat];
        uint numStrategies = deployedStrategyArray.length;

        // deploy proxy admin for ability to upgrade proxy contracts
        credibleAlignedLayerProxyAdmin = new ProxyAdmin();

        // deploy pauser registry
        {
            address[] memory pausers = new address[](2);
            pausers[0] = credibleAlignedLayerPauser;
            pausers[1] = credibleAlignedLayerCommunityMultisig;
            credibleAlignedLayerPauserReg = new PauserRegistry(
                pausers,
                credibleAlignedLayerCommunityMultisig
            );
        }

        EmptyContract emptyContract = new EmptyContract();

        // hard-coded inputs

        /**
         * First, deploy upgradeable proxy contracts that **will point** to the implementations. Since the implementation contracts are
         * not yet deployed, we give these proxies an empty contract as the initial implementation, to act as if they have no code.
         */
        credibleAlignedLayerServiceManager = AlignedLayerServiceManager(
            address(
                new TransparentUpgradeableProxy(
                    address(emptyContract),
                    address(credibleAlignedLayerProxyAdmin),
                    ""
                )
            )
        );
        credibleAlignedLayerTaskManager = AlignedLayerTaskManager(
            address(
                new TransparentUpgradeableProxy(
                    address(emptyContract),
                    address(credibleAlignedLayerProxyAdmin),
                    ""
                )
            )
        );
        registryCoordinator = blsregcoord.BLSRegistryCoordinatorWithIndices(
            address(
                new TransparentUpgradeableProxy(
                    address(emptyContract),
                    address(credibleAlignedLayerProxyAdmin),
                    ""
                )
            )
        );
        blsPubkeyRegistry = IBLSPubkeyRegistry(
            address(
                new TransparentUpgradeableProxy(
                    address(emptyContract),
                    address(credibleAlignedLayerProxyAdmin),
                    ""
                )
            )
        );
        indexRegistry = IIndexRegistry(
            address(
                new TransparentUpgradeableProxy(
                    address(emptyContract),
                    address(credibleAlignedLayerProxyAdmin),
                    ""
                )
            )
        );
        stakeRegistry = IStakeRegistry(
            address(
                new TransparentUpgradeableProxy(
                    address(emptyContract),
                    address(credibleAlignedLayerProxyAdmin),
                    ""
                )
            )
        );

        // Second, deploy the *implementation* contracts, using the *proxy contracts* as inputs
        {
            stakeRegistryImplementation = new StakeRegistry(
                registryCoordinator,
                strategyManager,
                credibleAlignedLayerServiceManager
            );

            // set up a quorum with each strategy that needs to be set up
            uint96[] memory minimumStakeForQuorum = new uint96[](numStrategies);
            IVoteWeigher.StrategyAndWeightingMultiplier[][]
                memory strategyAndWeightingMultipliers = new IVoteWeigher.StrategyAndWeightingMultiplier[][](
                    numStrategies
                );
            for (uint i = 0; i < numStrategies; i++) {
                strategyAndWeightingMultipliers[
                    i
                ] = new IVoteWeigher.StrategyAndWeightingMultiplier[](1);
                strategyAndWeightingMultipliers[i][0] = IVoteWeigher
                    .StrategyAndWeightingMultiplier({
                        strategy: deployedStrategyArray[i],
                        // setting this to 1 ether since the divisor is also 1 ether
                        // therefore this allows an operator to register with even just 1 token
                        // see ./eigenlayer-contracts/src/contracts/middleware/VoteWeigherBase.sol#L81
                        //    weight += uint96(sharesAmount * strategyAndMultiplier.multiplier / WEIGHTING_DIVISOR);
                        multiplier: 1 ether
                    });
            }

            credibleAlignedLayerProxyAdmin.upgradeAndCall(
                TransparentUpgradeableProxy(payable(address(stakeRegistry))),
                address(stakeRegistryImplementation),
                abi.encodeWithSelector(
                    StakeRegistry.initialize.selector,
                    minimumStakeForQuorum,
                    strategyAndWeightingMultipliers
                )
            );
        }

        registryCoordinatorImplementation = new blsregcoord.BLSRegistryCoordinatorWithIndices(
            slasher,
            credibleAlignedLayerServiceManager,
            blsregcoord.IStakeRegistry(address(stakeRegistry)),
            blsregcoord.IBLSPubkeyRegistry(address(blsPubkeyRegistry)),
            blsregcoord.IIndexRegistry(address(indexRegistry))
        );

        {
            blsregcoord.IBLSRegistryCoordinatorWithIndices.OperatorSetParam[]
                memory operatorSetParams = new blsregcoord.IBLSRegistryCoordinatorWithIndices.OperatorSetParam[](
                    numStrategies
                );
            for (uint i = 0; i < numStrategies; i++) {
                // hard code these for now
                operatorSetParams[i] = blsregcoord
                    .IBLSRegistryCoordinatorWithIndices
                    .OperatorSetParam({
                        maxOperatorCount: 10000,
                        kickBIPsOfOperatorStake: 15000,
                        kickBIPsOfTotalStake: 100
                    });
            }
            credibleAlignedLayerProxyAdmin.upgradeAndCall(
                TransparentUpgradeableProxy(
                    payable(address(registryCoordinator))
                ),
                address(registryCoordinatorImplementation),
                abi.encodeWithSelector(
                    blsregcoord
                        .BLSRegistryCoordinatorWithIndices
                        .initialize
                        .selector,
                    // we set churnApprover and ejector to communityMultisig because we don't need them
                    credibleAlignedLayerCommunityMultisig,
                    credibleAlignedLayerCommunityMultisig,
                    operatorSetParams,
                    credibleAlignedLayerPauserReg,
                    // 0 initialPausedStatus means everything unpaused
                    0
                )
            );
        }

        blsPubkeyRegistryImplementation = new BLSPubkeyRegistry(
            registryCoordinator,
            pubkeyCompendium
        );

        credibleAlignedLayerProxyAdmin.upgrade(
            TransparentUpgradeableProxy(payable(address(blsPubkeyRegistry))),
            address(blsPubkeyRegistryImplementation)
        );

        indexRegistryImplementation = new IndexRegistry(registryCoordinator);

        credibleAlignedLayerProxyAdmin.upgrade(
            TransparentUpgradeableProxy(payable(address(indexRegistry))),
            address(indexRegistryImplementation)
        );

        credibleAlignedLayerServiceManagerImplementation = new AlignedLayerServiceManager(
            registryCoordinator,
            slasher,
            credibleAlignedLayerTaskManager
        );
        // Third, upgrade the proxy contracts to use the correct implementation contracts and initialize them.
        credibleAlignedLayerProxyAdmin.upgradeAndCall(
            TransparentUpgradeableProxy(
                payable(address(credibleAlignedLayerServiceManager))
            ),
            address(credibleAlignedLayerServiceManagerImplementation),
            abi.encodeWithSelector(
                credibleAlignedLayerServiceManager.initialize.selector,
                credibleAlignedLayerPauserReg,
                credibleAlignedLayerCommunityMultisig
            )
        );

        credibleAlignedLayerTaskManagerImplementation = new AlignedLayerTaskManager(
            registryCoordinator,
            TASK_RESPONSE_WINDOW_BLOCK
        );

        // Third, upgrade the proxy contracts to use the correct implementation contracts and initialize them.
        credibleAlignedLayerProxyAdmin.upgradeAndCall(
            TransparentUpgradeableProxy(
                payable(address(credibleAlignedLayerTaskManager))
            ),
            address(credibleAlignedLayerTaskManagerImplementation),
            abi.encodeWithSelector(
                credibleAlignedLayerTaskManager.initialize.selector,
                credibleAlignedLayerPauserReg,
                credibleAlignedLayerCommunityMultisig,
                AGGREGATOR_ADDR,
                TASK_GENERATOR_ADDR,
                QUORUM_THRESHOLD_PERCENTAGE
            )
        );

        // WRITE JSON DATA
        string memory parent_object = "parent object";

        string memory deployed_addresses = "addresses";
        vm.serializeAddress(
            deployed_addresses,
            "erc20Mock",
            address(erc20Mock)
        );
        vm.serializeAddress(
            deployed_addresses,
            "erc20MockStrategy",
            address(erc20MockStrategy)
        );
        vm.serializeAddress(
            deployed_addresses,
            "alignedLayerServiceManager",
            address(credibleAlignedLayerServiceManager)
        );
        vm.serializeAddress(
            deployed_addresses,
            "alignedLayerServiceManagerImplementation",
            address(credibleAlignedLayerServiceManagerImplementation)
        );
        vm.serializeAddress(
            deployed_addresses,
            "alignedLayerTaskManager",
            address(credibleAlignedLayerTaskManager)
        );
        vm.serializeAddress(
            deployed_addresses,
            "alignedLayerTaskManagerImplementation",
            address(credibleAlignedLayerTaskManagerImplementation)
        );
        vm.serializeAddress(
            deployed_addresses,
            "registryCoordinator",
            address(registryCoordinator)
        );
        string memory deployed_addresses_output = vm.serializeAddress(
            deployed_addresses,
            "registryCoordinatorImplementation",
            address(registryCoordinatorImplementation)
        );

        // serialize all the data
        string memory finalJson = vm.serializeString(
            parent_object,
            deployed_addresses,
            deployed_addresses_output
        );

        writeOutput(finalJson, "aligned_layer_avs_deployment_output");
    }
}
