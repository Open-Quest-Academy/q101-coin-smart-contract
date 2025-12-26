# Q101 Token Smart Contracts - Security Audit Version

**Upgradeable ERC-20 Token with Airdrop and Vesting System**

This repository contains the core smart contracts for a token airdrop and vesting platform, designed for deployment on **BSC Mainnet**.

---

## 📋 Contract Overview

### 1. Q101Token.sol
Upgradeable ERC-20 token with the following features:
- **Fixed Supply**: 1 billion tokens (1,000,000,000) with 18 decimals
- **Configurable Name/Symbol**: Set during initialization
- **Pausable Transfers**: Emergency pause/unpause functionality
- **UUPS Upgradeable**: Controlled by Gnosis Safe multi-sig
- **Based on**: OpenZeppelin Contracts v5.0.0 (Upgradeable)

### 2. Q101AirdropVesting.sol
Sophisticated airdrop contract with three-stage vesting and commit-reveal pattern:

#### Core Features:
- **Commit-Reveal Mechanism**: Two-phase claiming to prevent front-running attacks
  - Phase 1: User commits with `keccak256(voucherId, user, amount, salt)`
  - Phase 2: User reveals data after configurable block delay (default: 3-31536000000 blocks)
- **Merkle Proof Verification**: Efficient eligibility verification using Merkle trees
- **Three-Stage Release Model**:
  1. **Immediate Release**: Configurable percentage (e.g., 10%) released at claim time
  2. **Cliff Period**: Optional cliff with lump sum release (e.g., 20% after 6 months)
  3. **Linear Vesting**: Remaining amount vests linearly over time
- **Flexible Withdrawal Restrictions**: Time-based OR amount-based thresholds
- **Gasless Transactions**: Integrated with Gelato Relay (ERC2771) for user convenience
- **UUPS Upgradeable**: Multi-sig controlled upgrades

#### Security Highlights:
- Commit-reveal prevents transaction front-running
- Configurable reveal delay window prevents race conditions
- Per-second precision in vesting calculations
- Comprehensive event logging for all critical operations

---

## 🏗️ Architecture

### Deployment Pattern: UUPS Proxy

Both contracts use the **UUPS (Universal Upgradeable Proxy Standard)** pattern:

```
User/Contract
     ↓
ERC1967Proxy (Storage + Fallback)
     ↓
Implementation Contract (Logic)
```

**Benefits**:
- Upgradeable logic without changing contract address
- State preserved across upgrades
- Gas-efficient (logic in implementation, state in proxy)
- Controlled by Gnosis Safe multi-sig

### Dual Vesting Configuration

Two separate vesting contracts with different parameters:

| Configuration | Shareholder Vesting | Team Vesting |
|---------------|---------------------|--------------|
| Duration      | 36 months (3 years) | 48 months (4 years) |
| Immediate Release | 10% (1000 basis points) | 5% (500 basis points) |
| Cliff Period  | Optional | Optional |
| Min Withdraw Interval | 30 days | 30 days |
| Min Withdraw Amount | 100 tokens | 200 tokens |
| Commit-Reveal Delay | 3-255 blocks | 3-255 blocks |

### Interaction Flow

```
┌─────────────┐     mints      ┌──────────────────┐
│ Q101Token   │───────────────>│  Gnosis Safe     │
│  (Proxy)    │                │  (Multi-sig)     │
└─────────────┘                └──────────────────┘
                                       │
                                       │ transfer tokens
                         ┌─────────────┴────────────────┐
                         │                              │
                         ▼                              ▼
              ┌──────────────────────┐      ┌──────────────────────┐
              │ Shareholder Vesting  │      │    Team Vesting      │
              │      (Proxy)         │      │      (Proxy)         │
              └──────────────────────┘      └──────────────────────┘
                         │                              │
                         │ commit-reveal claim          │
                         │ linear vesting               │
                         │ gasless withdraw             │
                         ▼                              ▼
                   ┌──────────┐                  ┌──────────┐
                   │  Users   │                  │  Users   │
                   └──────────┘                  └──────────┘
```

---

## 🔒 Security Model

### Commit-Reveal Pattern

**Purpose**: Prevents front-running attacks where malicious actors could observe pending transactions and submit their own with higher gas fees.

**Mechanism**:
1. **Commit Phase**:
   ```solidity
   bytes32 commitHash = keccak256(abi.encode(voucherId, user, amount, salt));
   vesting.commit(commitHash);  // Gasless via Gelato
   ```
   - User generates random salt (32 bytes)
   - Creates commitment hash (hides actual claim data)
   - Submits commitment on-chain

2. **Waiting Period**:
   - Minimum delay: `minRevealDelay` blocks (default: 3)
   - Maximum delay: `maxRevealDelay` blocks (default: 255)
   - Ensures attacker cannot immediately copy

3. **Reveal Phase**:
   ```solidity
   vesting.reveal(voucherId, amount, salt, merkleProof);  // Gasless via Gelato
   ```
   - User submits actual claim data
   - Contract verifies commitment matches
   - Validates Merkle proof
   - Creates vesting schedule

**Security Benefits**:
- ✅ Front-running impossible (data hidden in commit phase)
- ✅ Time delay prevents instant copying
- ✅ On-chain commitment provides proof of intent

### Merkle Proof Verification

**Leaf Hash Format** (double-hashed for security):
```solidity
bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(voucherId, amount))));
```

**Security Properties**:
- Efficient verification (O(log n) proofs for n allocations)
- Prevents second pre-image attacks
- Per-voucher claim tracking prevents replays

### Three-Stage Vesting Calculation

```solidity
// Stage 1: Immediate Release
immediateAmount = (totalAmount * immediateReleaseRatio) / 10000

// Stage 2: Cliff Release (optional)
if (block.timestamp >= cliffTime && cliffTime > 0) {
    cliffAmount = (totalAmount * cliffReleaseRatio) / 10000
}

// Stage 3: Linear Vesting
vestingBase = totalAmount - immediateAmount - cliffAmount
vestedAmount = (vestingBase * timeElapsed) / vestingDuration

// Total Releasable
releasable = immediateAmount + cliffAmount + vestedAmount - releasedAmount
```

**Precision**: Per-second vesting (no rounding to months)

### Withdrawal Restrictions

Users can withdraw when **ANY** of these conditions are met:
1. **Time-based**: `block.timestamp - lastWithdrawTime >= minWithdrawInterval`
2. **Amount-based**: `releasableAmount >= minWithdrawAmount`
3. **Vesting complete**: `block.timestamp >= vestingEndTime`

**Purpose**: Prevents dust transactions and gas waste

### Access Control

All critical operations protected by **Gnosis Safe multi-sig**:
- Setting Merkle root 
- Configuring airdrop parameters
- Updating withdrawal restrictions
- Pausing/unpausing operations
- Upgrading contract implementations
- Emergency token withdrawal

---

## 🚀 Deployment Guide

### Prerequisites

1. **Foundry** installed (`foundryup`)
2. **Gnosis Safe** multi-sig wallet deployed on BSC Mainnet
3. **Sufficient BNB** for deployment gas (~0.5 BNB recommended)
4. **BSCScan API Key** for contract verification

### Environment Setup

Create `.env` file (use `.env.example` as template):

```bash
# Deployer private key (will pay gas fees)
DEPLOYER_PRIVATE_KEY=0x...

# BSC Mainnet RPC URL
BSC_MAINNET_RPC=https://bsc-dataseed1.binance.org/

# BSCScan API Key (for verification)
BSCSCAN_API_KEY=your_api_key_here

# Your Gnosis Safe address (will own all contracts)
GNOSIS_SAFE=0x...
```

### Deployment Steps

#### Step 1: Update Configuration

Edit `script/DeployBSCMainnet.s.sol`:
- Line 16: Set `GNOSIS_SAFE` to your actual multi-sig address
- Lines 23-24: Configure token name and symbol (optional)

#### Step 2: Simulate Deployment

```bash
# Load environment variables
source .env

# Simulate deployment (no actual transactions)
forge script script/DeployBSCMainnet.s.sol:DeployBSCMainnet \
    --rpc-url $BSC_MAINNET_RPC \
    --sender $(cast wallet address --private-key $DEPLOYER_PRIVATE_KEY)
```

Review output for any errors.

#### Step 3: Deploy to BSC Mainnet

```bash
# Deploy and verify contracts
forge script script/DeployBSCMainnet.s.sol:DeployBSCMainnet \
    --rpc-url $BSC_MAINNET_RPC \
    --broadcast \
    --verify \
    -vvvv
```

**Expected Output**:
- Token Implementation address
- Token Proxy address (use this as token address)
- Shareholder Vesting Proxy address
- Team Vesting Proxy address

#### Step 4: Post-Deployment Configuration

All post-deployment steps must be executed via **Gnosis Safe** multi-sig:

1. **Set Merkle Roots**:
   ```solidity
   // Function: updateMerkleRoot(bytes32 _merkleRoot)
   shareholderVesting.updateMerkleRoot(0x...);
   teamVesting.updateMerkleRoot(0x...);
   ```

2. **Configure Airdrop Parameters**:
   ```solidity
   // Shareholder Vesting: 36 months total (6 cliff + 30 linear)
   // Release: 10% immediate + 20% cliff + 70% linear
   shareholderVesting.configureAirdrop(
       uint64(block.timestamp),  // startTime (Unix timestamp)
       merkleRoot,               // merkleRoot (from backend)
       77760000,                 // vestingDuration: 30 months in seconds (30 * 30 * 24 * 60 * 60)
       15552000,                 // cliffDuration: 6 months in seconds (6 * 30 * 24 * 60 * 60)
       1000,                     // immediateReleaseRatio: 10% (1000 basis points)
       2000,                     // cliffReleaseRatio: 20% (2000 basis points)
       VestingFrequency.PER_SECOND,  // vestingFrequency: 0 (per-second precision)
       2592000,                  // minWithdrawInterval: 30 days in seconds (30 * 24 * 60 * 60)
       100 * 10**18              // minWithdrawAmount: 100 tokens in wei
   );

   // Team Vesting: 48 months total (12 cliff + 36 linear)
   // Release: 5% immediate + 15% cliff + 80% linear
   teamVesting.configureAirdrop(
       uint64(block.timestamp),  // startTime
       merkleRoot,               // merkleRoot (from backend)
       93312000,                 // vestingDuration: 36 months in seconds (36 * 30 * 24 * 60 * 60)
       31104000,                 // cliffDuration: 12 months in seconds (12 * 30 * 24 * 60 * 60)
       500,                      // immediateReleaseRatio: 5% (500 basis points)
       1500,                     // cliffReleaseRatio: 15% (1500 basis points)
       VestingFrequency.PER_SECOND,  // vestingFrequency: 0
       2592000,                  // minWithdrawInterval: 30 days in seconds
       200 * 10**18              // minWithdrawAmount: 200 tokens in wei
   );
   ```

3. **Transfer Tokens** to vesting contracts:
   ```solidity
   // From Gnosis Safe to each vesting contract
   token.transfer(shareholderVestingAddress, shareholderAllocation);
   token.transfer(teamVestingAddress, teamAllocation);
   ```

### Verification on BSCScan

Manual verification if auto-verification fails:

```bash
# Verify Token Implementation
forge verify-contract <IMPLEMENTATION_ADDRESS> \
    src/Q101Token.sol:Q101Token \
    --chain bsc \
    --watch

# Verify Vesting Implementation
forge verify-contract <IMPLEMENTATION_ADDRESS> \
    src/Q101AirdropVesting.sol:Q101AirdropVesting \
    --chain bsc \
    --constructor-args $(cast abi-encode "constructor(address)" 0xd8253782c45a12053594b9deB72d8e8aB2Fca54c) \
    --watch
```

---

## 🧪 Testing

### Run All Tests

```bash
# Run all tests (74 total test cases)
forge test

# Run with verbosity
forge test -vvv

# Run with gas reporting
forge test --gas-report
```

### Test Coverage

```bash
# Generate coverage report
forge coverage

# Generate detailed HTML report
forge coverage --report lcov
genhtml lcov.info -o coverage/
```

**Expected Coverage**:
- **Q101Token**: 100% lines, 100% statements, 83% branches, 100% functions
- **Q101AirdropVesting**: 96%+ lines, 97%+ statements, 81%+ branches, 91%+ functions

### Test Structure

```
test/
├── Q101Token.t.sol                     # Token tests (16 test cases)
├── Q101AirdropVesting.t.sol            # Basic vesting tests (15 test cases)
├── Q101AirdropVesting_Extended.t.sol   # Extended scenarios (27 test cases)
├── Q101AirdropVesting_Final.t.sol      # Final edge cases (16 test cases)
└── mocks/
    └── MockFailingToken.sol            # Mock for failure scenarios
```

### Key Test Scenarios

**Q101Token**:
- ✅ Initialization and configuration
- ✅ Standard ERC-20 operations
- ✅ Pause/unpause functionality
- ✅ UUPS upgrade mechanism
- ✅ Access control

**Q101AirdropVesting**:
- ✅ Commit-reveal flow (happy path)
- ✅ Commit-reveal timing constraints
- ✅ Merkle proof verification
- ✅ Three-stage vesting calculations
- ✅ Withdrawal restrictions
- ✅ Pause/unpause
- ✅ Configuration updates
- ✅ Edge cases (zero amounts, max values, boundary conditions)
- ✅ Revert scenarios (all error paths)

---

## 🔍 Audit Scope

### In Scope

**Smart Contracts**:
1. `src/Q101Token.sol` (98 lines)
2. `src/Q101AirdropVesting.sol` (746 lines)

**Focus Areas**:
- Commit-reveal mechanism security
- Merkle proof validation
- Vesting calculation accuracy
- Integer overflow/underflow
- Reentrancy protection
- Access control
- Upgradability safety
- ERC2771 (Gelato) integration
- Event emissions
- Gas optimization opportunities

### Out of Scope

- Frontend DApp (not included)
- Backend API services (not included)
- Gelato Relay infrastructure (external dependency)
- OpenZeppelin library code (audited by OpenZeppelin)
- Deployment scripts (reference only)
- Test files (audit helpers only)

---

## 📐 Key Design Decisions

### 1. Why UUPS over Transparent Proxy?
- **Gas Efficiency**: Upgrade logic in implementation, not proxy
- **Smaller Proxy**: Simpler and cheaper to deploy
- **Explicit Upgrades**: `upgradeToAndCall()` must be called explicitly
- **Industry Standard**: Recommended by OpenZeppelin for new projects

### 2. Why Commit-Reveal?
- **Front-Running Protection**: Essential for fair airdrops
- **Proven Pattern**: Used in ENS auctions and other DeFi protocols
- **Configurable Delays**: Adaptable to network conditions

### 3. Why Merkle Trees?
- **Gas Efficiency**: O(log n) verification vs O(n) storage
- **Privacy**: Only revealed when claimed
- **Flexibility**: Easy to regenerate for multiple distributions

### 4. Why Three-Stage Vesting?
- **Flexibility**: Supports various tokenomics models
- **Immediate Liquidity**: Prevents complete lockup
- **Cliff Alignment**: Common in equity vesting (1-year cliff)
- **Linear Fairness**: Predictable release schedule

### 5. Why Gelato Relay (ERC2771)?
- **User Experience**: No gas fees for users
- **Adoption**: Lower barrier to entry
- **Security**: Trusted forwarder pattern (EIP-2771 standard)
- **Proven**: Used by major DeFi protocols

---

## ⚠️ Known Limitations & Assumptions

### Assumptions

1. **Gelato Relay Availability**: Assumes Gelato network remains operational
   - Fallback: Users can call functions directly (paying gas)
   - Mitigation: Monitor Gelato status and gas tank balance

2. **Gnosis Safe Security**: Assumes multi-sig signers act honestly
   - Mitigation: Use reputable signers and clear procedures
   - Recommendation: 3-of-5 or 5-of-7 multi-sig setup

3. **Merkle Root Accuracy**: Assumes correct off-chain Merkle tree generation
   - Mitigation: Thoroughly test tree generation before setting root

4. **Block Time Stability**: Assumes ~3 second block time on BSC
   - Reality: BSC block time is consistent at ~3 seconds
   - Impact: Reveal delay timing is predictable

### Limitations

1. **No Partial Reveals**: User must reveal entire voucher amount
   - Design: Simplifies logic and prevents gaming
   - Impact: Cannot split claims across multiple transactions

2**Fixed Vesting Parameters**: Cannot change vesting config per user
   - Design: Fairness and consistency
   - Workaround: Use separate vesting contracts for different tiers

3**ERC2771 Dependency**: Relies on Gelato's trusted forwarder
   - Mitigation: Functions work without Gelato (user pays gas)
   - Security: EIP-2771 is a standard with wide adoption

---

## 📚 Dependencies

### External Contracts

- **OpenZeppelin Contracts Upgradeable v5.0.0**:
  - `ERC20Upgradeable.sol`
  - `OwnableUpgradeable.sol`
  - `PausableUpgradeable.sol`
  - `UUPSUpgradeable.sol`
  - `ERC2771ContextUpgradeable.sol`
  - `Initializable.sol`

- **OpenZeppelin Contracts v5.0.0**:
  - `ERC1967Proxy.sol`
  - `IERC20.sol`
  - `MerkleProof.sol`

### Development Tools

- **Foundry** (forge, cast, anvil)
- **Solidity** 0.8.28 or higher
- **Node.js** (for Merkle tree generation)

### External Services

- **Gelato Relay**: Gasless transaction infrastructure
  - BSC Mainnet Forwarder: `0xd8253782c45a12053594b9deB72d8e8aB2Fca54c`
  - Documentation: https://docs.gelato.network/

- **Gnosis Safe**: Multi-sig wallet for admin operations
  - Documentation: https://docs.safe.global/

---

## 📞 Support

For audit-related questions, please refer to:
- Contract source code comments (extensive inline documentation)
- Test files (examples of all functionalities)
- This README (comprehensive guide)

---

## 📄 License

MIT License - See individual contract files for SPDX identifiers

---

**Audit Version**: 2.0
**Last Updated**: 2025-12-11
**Target Network**: BSC Mainnet (Chain ID: 56)
**Solidity Version**: ^0.8.28
**OpenZeppelin Version**: 5.0.0
