# ThyraAccount

ThyraAccount is a next-generation Smart Contract Account (SCA) system that combines the security of Gnosis Safe wallets with advanced execution capabilities through the EIP-2535 Diamond Proxy pattern. It enables pre-authorized, batched transaction execution through a Merkle tree-based task system, providing unprecedented flexibility for DeFi operations while maintaining robust security guarantees.

## Key Features

### Merkle Tree-Based Task System
- **Pre-Authorized Operations**: Define and commit to transaction batches using Merkle trees, storing only the root on-chain
- **Gas-Efficient Verification**: Execute operations with cryptographic proof validation without storing individual operations
- **Flexible Execution**: Operations can be executed in any order with independent proof validation
- **Non-Repeatable Protection**: Built-in bitmap tracking prevents double execution of sensitive operations

### Advanced Execution Controls
- **Time-Bounded Operations**: Each operation has configurable start and end timestamps for execution windows
- **Gas Price Protection**: Maximum gas price enforcement prevents execution during network congestion
- **Authorized Executors**: Designated executors with global whitelist validation through ThyraRegistry
- **Repeatable Operations**: Support for both one-time and recurring operations within the same task

### Diamond Proxy Architecture (EIP-2535)
- **Modular Upgradability**: Add, replace, or remove functionality without contract migration
- **Shared Facet Implementations**: All Diamond instances share pre-deployed facet implementations for gas efficiency
- **Fast Path Optimization**: Immutable default facets with gas-optimized lookup for common operations
- **Unlimited Contract Size**: Break through Ethereum's 24KB contract size limit

### Safe Integration
- **Multi-Signature Security**: Built on proven Gnosis Safe v1.5+ infrastructure
- **Module-Based Execution**: ThyraDiamond operates as a Safe module with `execTransactionFromModuleReturnData()`
- **Account Hierarchies**: Support for main accounts and sub-accounts with parent-child relationships
- **Safe Ownership**: Safe wallet owns and controls the Diamond proxy

### Fee Management System
- **Configurable Fee Tokens**: Support for any ERC20 token as payment for executor fees
- **Global Whitelist**: ThyraRegistry maintains approved executors and fee tokens
- **Fee Bounds**: Min/max fee validation ensures fair compensation and prevents abuse
- **Per-Task Configuration**: Each task can specify unique fee parameters

## Core Components

The system is built around several key components:

### Deployment Layer
- **ThyraFactory**: Unified factory for deploying Safe wallets with integrated ThyraDiamond modules
- **ThyraRegistry**: Global configuration and whitelist registry for executors and fee tokens

### Diamond Proxy Layer
- **ThyraDiamond**: EIP-2535 Diamond proxy with two-tiered function lookup (fast path + storage fallback)
- **DiamondCutFacet**: Core upgradeability facet for managing Diamond functions
- **DiamondLoupeFacet**: Introspection facet for querying Diamond configuration

### Execution Layer
- **ExecutorFacet**: Core task management and Merkle-proof-based execution engine
- **OwnershipFacet**: Ownership management and transfer functionality

### Utility Layer
- **LibDiamond**: EIP-2535 Diamond storage pattern implementation
- **LibDefaultFacets**: Fast path function selector mapping for default facets
- **SafeHelpers**: Utilities for Safe wallet interaction and MultiSend packing
- **BigMathMinified**: Compressed number representation for fee storage optimization
- **TypeHashHelper**: EIP-712 structured data hashing utilities

## Architecture Benefits

### Security-First Design
By integrating with Gnosis Safe's battle-tested multisig infrastructure and adding a Merkle-proof-based authorization layer, ThyraAccount provides defense-in-depth security suitable for institutional-grade operations.

### Gas Optimization
- **Shared Facet Implementations**: All Diamond instances delegate to the same facet contracts, eliminating redundant deployments
- **Bitmap Execution Tracking**: 88-bit bitmap efficiently tracks non-repeatable operation execution
- **Fast Path Lookup**: Default facets use immutable storage for gas-optimized function resolution
- **Compressed Fee Storage**: BigNumber format reduces fee storage from 96 bits to 48 bits

### Operational Flexibility
The Merkle tree task system enables complex multi-step workflows to be pre-authorized and executed independently, supporting use cases from simple batched transfers to sophisticated DeFi strategies.

### Developer Experience
Clear separation of concerns, comprehensive TypeScript integration guides, and extensive test coverage make it easy to build applications on ThyraAccount infrastructure.

## Use Cases

### DeFi Strategy Execution
- **Automated Portfolio Rebalancing**: Pre-approve complex swap sequences across multiple DEXes
- **Yield Farming**: Batch deposit, stake, and claim operations with time-based scheduling
- **Liquidity Management**: Coordinate add/remove liquidity operations across protocols

### Treasury Operations
- **Payroll Distribution**: Pre-authorize salary payments with execution windows for accounting periods
- **Batched Payments**: Combine multiple transfers into a single authorized task
- **Subscription Payments**: Repeatable operations for recurring payments

### High-Frequency Operations
- **MEV Protection**: Pre-authorize operations with gas price caps to prevent front-running
- **Arbitrage Strategies**: Execute complex arbitrage sequences with time-window constraints
- **Liquidation Protection**: Pre-approve emergency collateral management operations

### Cross-Protocol Integration
- **Protocol Migration**: Batch withdraw-from-A and deposit-to-B operations
- **Collateral Management**: Coordinate deposits, borrows, and swaps across lending protocols
- **Reward Harvesting**: Automate claim-and-reinvest flows across multiple yield sources

### Account Hierarchies
- **Sub-Account Isolation**: Create specialized Safe wallets for different operational purposes
- **Risk Segregation**: Isolate high-risk operations in sub-accounts with limited permissions
- **Operational Delegation**: Enable parent accounts to manage sub-account operations via module execution

## Technical Highlights

### Operation ID Bitmap (0-87)
The 88-bit bitmap provides efficient on-chain tracking of executed operations. This design choice balances gas efficiency with practical batch size limits, supporting up to 88 non-repeatable operations per task.

### Two-Tiered Function Lookup
ThyraDiamond implements a novel optimization: commonly-used default facets are checked via immutable storage (extremely low gas), falling back to Diamond storage only for custom facets. This provides the upgradeability of EIP-2535 with near-native-call performance.

### Merkle Proof Verification
Uses OpenZeppelin's battle-tested MerkleProof library with sorted (commutative) hashing, ensuring compatibility with standard tooling and providing maximum security for operation validation.

### Safe Module Integration
ThyraDiamond operates as a Safe module rather than a Guard or Fallback Handler, enabling transaction execution without requiring Safe owner signatures for each operation. This dramatically reduces coordination overhead while maintaining security through pre-authorization.

## Security Model

### Multi-Layered Authorization
1. **Safe Multi-Sig**: Owners must approve task registration
2. **Merkle Proof**: Operations must cryptographically prove inclusion in registered tree
3. **Executor Whitelist**: Only globally approved executors can execute operations
4. **Time Windows**: Operations enforce temporal bounds
5. **Gas Price Caps**: Execution reverts if network conditions exceed limits

### Non-Repeatable Protection
The 88-bit execution bitmap ensures that non-repeatable operations cannot be executed twice, preventing replay attacks and accidental double-execution.

### Global Registry Validation
ThyraRegistry provides centralized validation of executors and fee tokens, enabling rapid response to security incidents by removing malicious actors from the whitelist.

### Immutable Facet References
While Diamond's function selector mapping is upgradeable, the default facet addresses are stored in immutable variables, providing gas optimization without sacrificing upgradeability for custom facets.

## Deployment Architecture

### Shared Facet Model
All ThyraDiamond instances share the same pre-deployed facet implementations:
- DiamondCutFacet (single deployment)
- DiamondLoupeFacet (single deployment)
- ExecutorFacet (single deployment, configured with ThyraRegistry address)
- OwnershipFacet (single deployment)

This dramatically reduces deployment costs while ensuring consistency across all Diamond instances.

### Deterministic Deployment
Both Safe wallets and ThyraDiamond proxies are deployed using CREATE2 with collision-resistant nonce generation, enabling predictable addresses for off-chain computation and testing.

### Atomic Initialization
The deployment flow atomically:
1. Deploys ThyraDiamond with Factory as temporary owner
2. Deploys Safe with Diamond already enabled as module
3. Transfers Diamond ownership to Safe
4. Emits unified deployment event

This ensures no window exists where either component is in an inconsistent state.

## Future Enhancements

### Potential Extensions
- **Flash Loan Integration**: Native support for Aave/Balancer flash loans within task execution
- **Signature Aggregation**: Batch multiple operations with aggregated signatures
- **Conditional Execution**: Support for operations with on-chain condition validation
- **Multi-Chain Coordination**: Cross-chain operation synchronization via message passing

### Ecosystem Integration
- **SDK Development**: TypeScript/Python SDKs for simplified integration
- **Subgraph Indexing**: The Graph protocol indexing for historical task analysis
- **Monitoring Tools**: Real-time dashboards for task execution tracking
- **Automation Services**: Off-chain executor infrastructure for automated task execution

---

ThyraAccount represents a significant advancement in smart contract wallet technology, combining the security of Gnosis Safe with the flexibility of EIP-2535 and the efficiency of Merkle tree-based authorization. It provides the foundation for sophisticated DeFi operations while maintaining the security guarantees users expect.

**Version**: 1.0.0  
**License**: LGPL-3.0-only


