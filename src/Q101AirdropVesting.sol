// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/metatx/ERC2771ContextUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/**
 * @title Q101AirdropVesting
 * @notice Airdrop contract with Merkle proof verification and three-stage vesting using Commit-Reveal pattern
 * @dev Upgradeable contract with emergency pause/unpause and UUPS upgradeability
 *      Users claim tokens via gasless transactions (Gelato Relay) using two-phase commit-reveal
 *      Phase 1: User commits with hash of (voucherId, to, amount, salt)
 *      Phase 2: User reveals data after minRevealDelay blocks, contract verifies and releases tokens
 *      Three-stage release model:
 *        Stage 1 (Immediate): A percentage released immediately at claim (e.g., 10%)
 *        Stage 2 (Cliff): A percentage released when cliff period ends (e.g., 20% after 6 months)
 *        Stage 3 (Linear Vesting): Remaining percentage vests linearly (e.g., 70% over 30 months)
 *      All users share the same vesting start time (configured via configureAirdrop)
 *      Users can withdraw when: time since last withdrawal >= minWithdrawInterval OR accumulated amount >= minWithdrawAmount
 *      Withdrawals: withdraw() is gasless via Gelato Relay
 */
contract Q101AirdropVesting is
    Initializable,
    OwnableUpgradeable,
    PausableUpgradeable,
    ERC2771ContextUpgradeable,
    UUPSUpgradeable
{
    // ============ Enums ============

    /// @notice Release frequency for linear vesting
    enum VestingFrequency {
        PER_SECOND,  // 0: Release per second (most precise)
        PER_DAY,     // 1: Release per day
        PER_MONTH    // 2: Release per month (30 days)
    }

    // ============ Structs ============

    struct VestingSchedule {
        uint64 startTime;
        uint64 duration;
        uint256 totalAmount;        // Total allocated amount
        uint256 immediateAmount;    // Immediate release amount (kept for compatibility)
        uint256 releasedAmount;     // Total released so far (including immediate)
        uint64 lastWithdrawTime;
    }

    struct Commitment {
        address committer;
        uint256 blockNumber;
        bool revealed;
    }

    // ============ Basic State (Initialize - Cannot Change) ============

    /// @notice Q101 Token contract
    IERC20 public token;

    // ============ Core Vesting Configuration State (configureAirdrop - Set Once) ============

    /// @notice Vesting start time (same for all users)
    /// @dev Set once via configureAirdrop()
    uint64 public startTime;

    /// @notice Merkle root for airdrop verification
    /// @dev Can only be set once via configureAirdrop()
    bytes32 public merkleRoot;

    /// @notice Vesting duration in seconds (linear vesting period, excluding cliff)
    /// @dev Set once via configureAirdrop()
    uint256 public vestingDuration;

    /// @notice Cliff period duration in seconds
    /// @dev Set once via configureAirdrop()
    uint256 public cliffDuration;

    /// @notice Immediate release ratio (in basis points, e.g., 1000 = 10%)
    /// @dev Set once via configureAirdrop()
    uint256 public immediateReleaseRatio;

    /// @notice Cliff release ratio (in basis points, e.g., 2000 = 20%)
    /// @dev Set once via configureAirdrop()
    uint256 public cliffReleaseRatio;

    /// @notice Vesting frequency mode for linear vesting
    /// @dev Set once via configureAirdrop()
    VestingFrequency public vestingFrequency;

    // ============ Adjustable Parameters (Can Update Anytime) ============

    /// @notice Minimum time interval between withdrawals (in seconds)
    /// @dev Can be updated via updateWithdrawRestrictions()
    uint256 public minWithdrawInterval;

    /// @notice Minimum accumulated amount required for withdrawal (in wei)
    /// @dev Can be updated via updateWithdrawRestrictions()
    uint256 public minWithdrawAmount;

    /// @notice Minimum blocks to wait between commit and reveal
    uint256 public minRevealDelay;

    /// @notice Maximum blocks allowed to reveal after commit
    uint256 public maxRevealDelay;

    // ============ Constants ============

    /// @notice Ratio precision constant (10000 = 100%)
    uint256 public constant RATIO_PRECISION = 10000;

    // ============ Mappings ============

    /// @notice Mapping from commitment hash to commitment data
    mapping(bytes32 => Commitment) public commitments;

    /// @notice Mapping from voucher ID to claimed status
    mapping(bytes32 => bool) public claimedVouchers;

    /// @notice Mapping from leaf hash to claimed status
    /// @dev leafHash = keccak256(bytes.concat(keccak256(abi.encode(voucherId, amount))))
    mapping(bytes32 => bool) public claimedLeafHashes;

    /// @notice Mapping from user address to vesting schedule
    mapping(address => VestingSchedule) public vestingSchedules;

    // ============ Events ============

    event Committed(address indexed user, bytes32 indexed commitHash);
    event Revealed(address indexed user, bytes32 indexed voucherId, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount, uint256 lastWithdrawTime);
    event VestingScheduleCreated(address indexed user, uint256 totalAmount, uint256 startTime);
    event EmergencyWithdrawn(address indexed owner, uint256 amount);
    event WithdrawRestrictionsUpdated(uint256 minInterval, uint256 minAmount);
    event RevealDelayUpdated(uint256 minDelay, uint256 maxDelay);
    event MerkleRootUpdated(bytes32 indexed oldRoot, bytes32 indexed newRoot);

    /// @notice Emitted when airdrop is configured (includes all vesting parameters)
    event AirdropConfigured(
        uint64 indexed startTime,
        bytes32 indexed merkleRoot,
        uint256 vestingDuration,
        uint256 cliffDuration,
        uint256 immediateReleaseRatio,
        uint256 cliffReleaseRatio,
        VestingFrequency vestingFrequency,
        uint256 minWithdrawInterval,
        uint256 minWithdrawAmount
    );

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address trustedForwarder_) ERC2771ContextUpgradeable(trustedForwarder_) {
        _disableInitializers();
    }

    /**
     * @notice Initialize the contract (replaces constructor for upgradeable contracts)
     * @dev Only sets basic immutable parameters
     *      All vesting configuration must be done via configureAirdrop() after deployment
     * @param _token Q101 Token address
     * @param _minRevealDelay Minimum blocks to wait between commit and reveal
     * @param _maxRevealDelay Maximum blocks allowed to reveal after commit
     * @param _owner Contract owner (Gnosis Safe)
     */
    function initialize(
        address _token,
        uint256 _minRevealDelay,
        uint256 _maxRevealDelay,
        address _owner
    ) public initializer {
        require(_token != address(0), "Invalid token address");
        require(_minRevealDelay > 0, "Invalid min reveal delay");
        require(_maxRevealDelay > _minRevealDelay, "Invalid max reveal delay");

        __Ownable_init(_owner);
        __Pausable_init();

        token = IERC20(_token);
        minRevealDelay = _minRevealDelay;
        maxRevealDelay = _maxRevealDelay;

        // Initialize to zero (will be set via configureAirdrop)
        merkleRoot = bytes32(0);
        startTime = 0;
    }

    // ============ Pause/Unpause Functions ============

    /**
     * @notice Pause all claims and withdrawals
     * @dev Can only be called by owner (Gnosis Safe)
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause all claims and withdrawals
     * @dev Can only be called by owner (Gnosis Safe)
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    // ============ Configuration Functions ============

    /**
     * @notice Configure airdrop with all vesting parameters (can only be called once)
     * @dev This is the ONLY way to set startTime, merkle root and vesting parameters
     *      All parameters are set atomically to ensure consistency
     *      Can only be called when merkleRoot is bytes32(0)
     *      Withdraw restrictions (minWithdrawInterval, minWithdrawAmount) are set initially
     *      but can be updated later via updateWithdrawRestrictions()
     * @param _startTime Vesting start time (unix timestamp)
     * @param _merkleRoot Merkle root for airdrop verification
     * @param _vestingDuration Linear vesting duration in seconds (e.g., 30 * 30 days)
     * @param _cliffDuration Cliff period duration in seconds (e.g., 6 * 30 days)
     * @param _immediateReleaseRatio Immediate release ratio in basis points (e.g., 1000 = 10%)
     * @param _cliffReleaseRatio Cliff release ratio in basis points (e.g., 2000 = 20%)
     * @param _vestingFrequency Vesting frequency mode (0=PER_SECOND, 1=PER_DAY, 2=PER_MONTH)
     * @param _minWithdrawInterval Initial minimum time interval between withdrawals (in seconds)
     * @param _minWithdrawAmount Initial minimum accumulated amount required for withdrawal (in wei)
     */
    function configureAirdrop(
        uint64 _startTime,
        bytes32 _merkleRoot,
        uint256 _vestingDuration,
        uint256 _cliffDuration,
        uint256 _immediateReleaseRatio,
        uint256 _cliffReleaseRatio,
        VestingFrequency _vestingFrequency,
        uint256 _minWithdrawInterval,
        uint256 _minWithdrawAmount
    ) external onlyOwner {
        // ============ Validation ============

        // Can only be called once (when merkleRoot is not set)
        require(merkleRoot == bytes32(0), "Airdrop already configured");

        // Validate startTime
        require(_startTime > 0, "Invalid start time");

        // Merkle root must be non-zero
        require(_merkleRoot != bytes32(0), "Invalid merkle root");

        // Vesting parameters validation
        require(_vestingDuration > 0, "Invalid vesting duration");
        require(_minWithdrawInterval > 0, "Invalid min withdraw interval");
        require(_minWithdrawAmount > 0, "Invalid min withdraw amount");

        // Release ratios validation
        require(
            _immediateReleaseRatio + _cliffReleaseRatio <= RATIO_PRECISION,
            "Immediate + Cliff ratio must <= 100%"
        );

        // Vesting frequency and duration divisibility validation
        // Ensure vesting duration and cliff duration are compatible with vesting frequency
        // to prevent precision loss and ensure uniform token release
        if (_vestingFrequency == VestingFrequency.PER_DAY) {
            require(
                _vestingDuration % 1 days == 0,
                "Vesting duration must be multiple of 1 day for PER_DAY mode"
            );
            if (_cliffDuration > 0) {
                require(
                    _cliffDuration % 1 days == 0,
                    "Cliff duration must be multiple of 1 day for PER_DAY mode"
                );
            }
        } else if (_vestingFrequency == VestingFrequency.PER_MONTH) {
            require(
                _vestingDuration % 30 days == 0,
                "Vesting duration must be multiple of 30 days for PER_MONTH mode"
            );
            if (_cliffDuration > 0) {
                require(
                    _cliffDuration % 30 days == 0,
                    "Cliff duration must be multiple of 30 days for PER_MONTH mode"
                );
            }
        }
        // Note: PER_SECOND mode has no divisibility requirements (supports any duration)

        // ============ Set All Parameters Atomically ============

        startTime = _startTime;
        merkleRoot = _merkleRoot;
        vestingDuration = _vestingDuration;
        cliffDuration = _cliffDuration;
        immediateReleaseRatio = _immediateReleaseRatio;
        cliffReleaseRatio = _cliffReleaseRatio;
        vestingFrequency = _vestingFrequency;

        // Set initial withdraw restrictions (can be updated later)
        minWithdrawInterval = _minWithdrawInterval;
        minWithdrawAmount = _minWithdrawAmount;

        // ============ Emit Event ============

        emit AirdropConfigured(
            _startTime,
            _merkleRoot,
            _vestingDuration,
            _cliffDuration,
            _immediateReleaseRatio,
            _cliffReleaseRatio,
            _vestingFrequency,
            _minWithdrawInterval,
            _minWithdrawAmount
        );
    }

    /**
     * @notice Check if airdrop has been configured
     * @return bool True if configured (merkleRoot is set)
     */
    function isAirdropConfigured() external view returns (bool) {
        return merkleRoot != bytes32(0);
    }

    /**
     * @notice Update Merkle Root with new users (can be called multiple times)
     * @dev Only updates merkleRoot, all other vesting parameters remain unchanged
     *      This function is used after initial configuration to add new users
     * @param _merkleRoot New Merkle root (includes all users: existing + new)
     */
    function updateMerkleRoot(bytes32 _merkleRoot) external onlyOwner {
        require(merkleRoot != bytes32(0), "Must call configureAirdrop first");
        require(_merkleRoot != bytes32(0), "Invalid merkle root");

        bytes32 oldRoot = merkleRoot;
        merkleRoot = _merkleRoot;

        emit MerkleRootUpdated(oldRoot, _merkleRoot);
    }

    /**
     * @notice Get all airdrop configuration
     * @return _startTime Vesting start time
     * @return _merkleRoot Merkle root
     * @return _vestingDuration Linear vesting duration
     * @return _cliffDuration Cliff period duration
     * @return _immediateReleaseRatio Immediate release ratio
     * @return _cliffReleaseRatio Cliff release ratio
     * @return _vestingFrequency Vesting frequency mode
     * @return _minWithdrawInterval Minimum withdraw interval
     * @return _minWithdrawAmount Minimum withdraw amount
     */
    function getAirdropConfig() external view returns (
        uint64 _startTime,
        bytes32 _merkleRoot,
        uint256 _vestingDuration,
        uint256 _cliffDuration,
        uint256 _immediateReleaseRatio,
        uint256 _cliffReleaseRatio,
        VestingFrequency _vestingFrequency,
        uint256 _minWithdrawInterval,
        uint256 _minWithdrawAmount
    ) {
        return (
            startTime,
            merkleRoot,
            vestingDuration,
            cliffDuration,
            immediateReleaseRatio,
            cliffReleaseRatio,
            vestingFrequency,
            minWithdrawInterval,
            minWithdrawAmount
        );
    }

    /**
     * @notice Update withdrawal restrictions (only owner - Gnosis Safe)
     * @dev Can be called multiple times, even after airdrop is configured
     *      Allows adjusting withdraw restrictions based on actual usage and market conditions
     * @param _minWithdrawInterval New minimum time interval between withdrawals (in seconds)
     * @param _minWithdrawAmount New minimum accumulated amount required for withdrawal (in wei)
     */
    function updateWithdrawRestrictions(uint256 _minWithdrawInterval, uint256 _minWithdrawAmount) external onlyOwner {
        require(_minWithdrawInterval > 0, "Invalid min withdraw interval");
        require(_minWithdrawAmount > 0, "Invalid min withdraw amount");

        minWithdrawInterval = _minWithdrawInterval;
        minWithdrawAmount = _minWithdrawAmount;

        emit WithdrawRestrictionsUpdated(_minWithdrawInterval, _minWithdrawAmount);
    }

    /**
     * @notice Update reveal delay parameters (only owner - Gnosis Safe)
     * @param _minRevealDelay New minimum blocks to wait between commit and reveal
     * @param _maxRevealDelay New maximum blocks allowed to reveal after commit
     */
    function updateRevealDelay(uint256 _minRevealDelay, uint256 _maxRevealDelay) external onlyOwner {
        require(_minRevealDelay > 0, "Invalid min reveal delay");
        require(_maxRevealDelay > _minRevealDelay, "Invalid max reveal delay");

        minRevealDelay = _minRevealDelay;
        maxRevealDelay = _maxRevealDelay;

        emit RevealDelayUpdated(_minRevealDelay, _maxRevealDelay);
    }

    // ============ Commit-Reveal Functions ============

    /**
     * @notice Commit to a claim by submitting commitment hash (gasless via Gelato Relay)
     * @dev First step of commit-reveal mechanism to prevent front-running
     *      Uses ERC2771 to get real user address from _msgSender()
     * @param commitHash Hash of keccak256(abi.encode(voucherId, user, amount, salt))
     */
    function commit(
        bytes32 commitHash
    ) external whenNotPaused {
        // 1. Get real user address via ERC2771
        address user = _msgSender();

        // 2. Check that merkleRoot has been set and commitment doesn't already exist
        require(merkleRoot != bytes32(0), "Airdrop not started: merkle root not set");
        require(commitments[commitHash].blockNumber == 0, "Commit: Already committed");

        // 3. Store commitment
        commitments[commitHash] = Commitment({
            committer: user,
            blockNumber: block.number,
            revealed: false
        });

        emit Committed(user, commitHash);
    }

    /**
     * @notice Reveal the committed data and execute claim (gasless via Gelato Relay)
     * @dev Second step of commit-reveal mechanism, creates vesting schedule and releases tokens
     *      Uses ERC2771 to get real user address from _msgSender()
     * @param voucherId Unique voucher ID
     * @param amount Total allocation amount (in wei)
     * @param salt Random salt used in commitment
     * @param merkleProof Merkle proof for verification
     */
    function reveal(
        bytes32 voucherId,
        uint256 amount,
        bytes32 salt,
        bytes32[] calldata merkleProof
    ) external whenNotPaused {
        // 0. Get real user address via ERC2771
        address user = _msgSender();

        // 1. Check that merkleRoot has been set
        require(merkleRoot != bytes32(0), "Airdrop not started: merkle root not set");

        // 2. Reconstruct commitment hash
        bytes32 commitHash = keccak256(abi.encode(voucherId, user, amount, salt));

        // 3. Verify commitment exists
        Commitment storage commitment = commitments[commitHash];
        require(commitment.blockNumber > 0, "Reveal: No commitment found");
        require(!commitment.revealed, "Reveal: Already revealed");
        require(commitment.committer == user, "Reveal: Wrong committer");

        // 4. Check timing constraints
        uint256 blocksPassed = block.number - commitment.blockNumber;
        require(blocksPassed >= minRevealDelay, "Reveal: Too early");

        // 5. Check voucher not claimed yet and user has no existing vesting schedule
        require(!claimedVouchers[voucherId], "Reveal: Voucher already claimed");
        require(vestingSchedules[user].totalAmount == 0, "Reveal: User already has vesting schedule");

        // 6. Calculate leaf hash
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(voucherId, amount))));

        // 7. Verify Merkle proof
        require(MerkleProof.verify(merkleProof, merkleRoot, leaf), "Reveal: Invalid Merkle proof");

        // 8. Mark as revealed and claimed (both voucherId and leafHash)
        commitment.revealed = true;
        claimedVouchers[voucherId] = true;
        claimedLeafHashes[leaf] = true;

        // 9. Create vesting schedule and release tokens
        _createAndWithdrawImmediatelyReleasable(user, amount);

        emit Revealed(user, voucherId, amount);
    }

    /**
     * @notice Internal function to create vesting schedule and release immediate ratio + releasable amount
     * @dev Three-stage release model:
     *      Stage 1 (Immediate): immediateAmount = totalAmount × immediateReleaseRatio
     *      Stage 2 (Cliff): cliffAmount = totalAmount × cliffReleaseRatio (released at cliff end)
     *      Stage 3 (Linear Vesting): vestingBase = totalAmount - immediateAmount - cliffAmount
     * @param user Recipient address
     * @param amount Total allocation amount
     */
    function _createAndWithdrawImmediatelyReleasable(address user, uint256 amount) internal {

        // Calculate immediate release amount (Stage 1)
        uint256 immediateAmount = (amount * immediateReleaseRatio) / RATIO_PRECISION;

        // Create vesting schedule
        vestingSchedules[user] = VestingSchedule({
            startTime: startTime,
            duration: uint64(vestingDuration),
            totalAmount: amount,
            immediateAmount: immediateAmount,
            releasedAmount: 0,
            lastWithdrawTime: uint64(block.timestamp)
        });

        emit VestingScheduleCreated(user, amount, startTime);

        // Calculate total releasable amount (includes immediate + vested)
        uint256 totalClaimAmount = _calculateReleasable(user);

        // Update released amount
        vestingSchedules[user].releasedAmount = totalClaimAmount;

        // Transfer tokens
        if (totalClaimAmount > 0) {
            require(token.transfer(user, totalClaimAmount), "Transfer failed");
        }
    }

    // ============ Withdraw Functions ============

    /**
     * @notice Withdraw vested tokens for caller (gasless via Gelato)
     * @dev Uses ERC2771 to get real user address from _msgSender()
     *      The tokens are sent to the caller's address
     */
    function withdraw() external whenNotPaused {
        address user = _msgSender();

        VestingSchedule storage schedule = vestingSchedules[user];
        require(schedule.totalAmount > 0, "Withdraw: No vesting schedule");

        uint256 releasableAmount = _calculateReleasable(user);
        require(releasableAmount > 0, "Withdraw: No tokens available");

        // Check withdrawal restrictions
        require(_checkWithdrawRestrictions(user, releasableAmount), "Withdraw: Restrictions not met");

        // Update released amount and last withdraw time
        schedule.releasedAmount += releasableAmount;
        schedule.lastWithdrawTime = uint64(block.timestamp);

        emit Withdrawn(user, releasableAmount, block.timestamp);

        // Transfer tokens to the user
        require(token.transfer(user, releasableAmount), "Transfer failed");
    }

    /**
     * @notice Calculate releasable amount for a user based on three-stage model
     * @dev Three-stage model:
     *      Stage 1 (Immediate): Released at reveal, always available
     *      Stage 2 (Cliff): Released when cliff period ends (one-time release)
     *      Stage 3 (Linear Vesting): Starts after cliff ends, released based on vestingFrequency
     * @param user User address
     * @return Releasable token amount
     */
    function _calculateReleasable(address user) internal view returns (uint256) {
        VestingSchedule storage schedule = vestingSchedules[user];

        if (schedule.totalAmount == 0) {
            return 0;
        }

        // Stage 1: Immediate release amount (always available after reveal)
        uint256 immediateAmount = (schedule.totalAmount * immediateReleaseRatio) / RATIO_PRECISION;

        // Stage 2: Cliff release amount (available after cliff ends)
        uint256 cliffAmount = (schedule.totalAmount * cliffReleaseRatio) / RATIO_PRECISION;

        // Stage 3: Linear vesting base
        uint256 vestingBase = schedule.totalAmount - immediateAmount - cliffAmount;

        uint256 vestedAmount = 0;

        // If current time is before vesting start, no vested tokens yet
        if (block.timestamp < schedule.startTime) {
            vestedAmount = 0;
        } else {
            uint256 elapsed = block.timestamp - schedule.startTime;

            // During cliff period: no additional release
            if (elapsed < cliffDuration) {
                vestedAmount = 0;
            } else {
                // After cliff: cliff amount + linear vesting
                uint256 vestingElapsed = elapsed - cliffDuration;

                // Calculate linear vested amount based on frequency
                uint256 linearVested = _calculateLinearVested(
                    vestingBase,
                    vestingElapsed,
                    schedule.duration
                );

                // Total vested = cliff release + linear vested
                vestedAmount = cliffAmount + linearVested;
            }
        }

        // Total vested including immediate = immediateAmount + vestedAmount
        uint256 totalVested = immediateAmount + vestedAmount;

        // Return releasable amount (total vested - already released)
        return totalVested > schedule.releasedAmount ? totalVested - schedule.releasedAmount : 0;
    }

    /**
     * @notice Calculate linear vested amount based on vesting frequency
     * @param vestingBase Total amount for linear vesting
     * @param vestingElapsed Time elapsed since cliff ended (in seconds)
     * @param duration Total vesting duration (in seconds)
     * @return Linear vested amount
     */
    function _calculateLinearVested(
        uint256 vestingBase,
        uint256 vestingElapsed,
        uint256 duration
    ) internal view returns (uint256) {
        // If vesting period completed, return all
        if (vestingElapsed >= duration) {
            return vestingBase;
        }

        // Calculate based on frequency mode
        if (vestingFrequency == VestingFrequency.PER_SECOND) {
            // Per second: most precise
            return (vestingBase * vestingElapsed) / duration;
        }
        else if (vestingFrequency == VestingFrequency.PER_DAY) {
            // Per day: vests once per day
            uint256 totalDays = duration / 1 days;
            uint256 elapsedDays = vestingElapsed / 1 days;

            if (elapsedDays >= totalDays) {
                return vestingBase;
            }
            return (vestingBase * elapsedDays) / totalDays;
        }
        else if (vestingFrequency == VestingFrequency.PER_MONTH) {
            // Per month: vests once per 30 days
            uint256 totalMonths = duration / 30 days;
            uint256 elapsedMonths = vestingElapsed / 30 days;

            if (elapsedMonths >= totalMonths) {
                return vestingBase;
            }
            return (vestingBase * elapsedMonths) / totalMonths;
        }

        return 0;
    }

    /**
     * @notice Check if withdrawal restrictions are met
     * @param user User address
     * @param releasableAmount Amount available to withdraw
     * @return True if restrictions are met (time interval OR amount threshold OR vesting completed)
     */
    function _checkWithdrawRestrictions(address user, uint256 releasableAmount) internal view returns (bool) {
        VestingSchedule storage schedule = vestingSchedules[user];

        // Check if vesting period has completed (including cliff period)
        uint256 vestingEndTime = schedule.startTime + cliffDuration + schedule.duration;
        bool vestingCompleted = block.timestamp >= vestingEndTime;

        // If vesting is completed, allow withdrawal without restrictions
        if (vestingCompleted) {
            return true;
        }

        // Check restrictions using CURRENT parameter values
        uint256 timeSinceLastWithdraw = block.timestamp - schedule.lastWithdrawTime;

        // User can withdraw if:
        // 1. Enough time has passed (>= minWithdrawInterval)
        // 2. OR accumulated amount is large enough (>= minWithdrawAmount)
        return timeSinceLastWithdraw >= minWithdrawInterval || releasableAmount >= minWithdrawAmount;
    }

    /**
     * @notice Get releasable amount for a user (public view function)
     * @param user User address
     * @return Releasable token amount
     */
    function getReleasableAmount(address user) external view returns (uint256) {
        return _calculateReleasable(user);
    }

    /**
     * @notice Get detailed vesting info for a user
     * @param user User address
     * @return totalAmount Total allocated amount
     * @return immediateAmount Immediate release amount
     * @return cliffAmount Cliff release amount
     * @return vestingBase Linear vesting base amount
     * @return releasedAmount Already released amount
     * @return releasableAmount Currently releasable amount
     */
    function getVestingInfo(address user) external view returns (
        uint256 totalAmount,
        uint256 immediateAmount,
        uint256 cliffAmount,
        uint256 vestingBase,
        uint256 releasedAmount,
        uint256 releasableAmount
    ) {
        VestingSchedule storage schedule = vestingSchedules[user];

        totalAmount = schedule.totalAmount;
        immediateAmount = (totalAmount * immediateReleaseRatio) / RATIO_PRECISION;
        cliffAmount = (totalAmount * cliffReleaseRatio) / RATIO_PRECISION;
        vestingBase = totalAmount - immediateAmount - cliffAmount;
        releasedAmount = schedule.releasedAmount;
        releasableAmount = _calculateReleasable(user);
    }

    // ============ Emergency Functions ============

    /**
     * @notice Emergency withdraw tokens (only owner - Gnosis Safe)
     * @param amount Amount to withdraw
     */
    function emergencyWithdraw(uint256 amount) external onlyOwner {
        emit EmergencyWithdrawn(owner(), amount);
        require(token.transfer(owner(), amount), "Transfer failed");
    }

    /**
     * @notice Emergency withdraw all token balance (only owner - Gnosis Safe)
     * @dev Withdraws entire token balance held by this contract to the owner
     */
    function emergencyWithdrawAll() external onlyOwner {
        uint256 balance = token.balanceOf(address(this));
        require(balance > 0, "No balance to withdraw");
        emit EmergencyWithdrawn(owner(), balance);
        require(token.transfer(owner(), balance), "Transfer failed");
    }

    // ============ Internal Functions ============

    /**
     * @notice Override _contextSuffixLength to support ERC2771
     * @dev Returns the length of the context suffix for ERC2771 meta-transactions
     * @return The context suffix length (20 bytes for address)
     */
    function _contextSuffixLength() internal view override(ContextUpgradeable, ERC2771ContextUpgradeable) returns (uint256) {
        return ERC2771ContextUpgradeable._contextSuffixLength();
    }

    /**
     * @notice Override _msgSender to support ERC2771 meta-transactions
     * @dev Returns the original sender when called through trusted forwarder
     * @return sender The real transaction sender
     */
    function _msgSender() internal view override(ContextUpgradeable, ERC2771ContextUpgradeable) returns (address sender) {
        return ERC2771ContextUpgradeable._msgSender();
    }

    /**
     * @notice Override _msgData to support ERC2771 meta-transactions
     * @dev Returns the original call data when called through trusted forwarder
     * @return The real transaction data
     */
    function _msgData() internal view override(ContextUpgradeable, ERC2771ContextUpgradeable) returns (bytes calldata) {
        return ERC2771ContextUpgradeable._msgData();
    }

    /**
     * @notice Authorize upgrade (required by UUPSUpgradeable)
     * @dev Can only be called by owner (Gnosis Safe)
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /**
     * @notice Get the version of the contract
     * @return Version string
     */
    function version() external pure returns (string memory) {
        return "1.0.0";
    }
}
