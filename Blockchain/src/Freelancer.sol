// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.28;

contract Freelancer {
    // ------------------------------------------------------------------
    // Constants
    // ------------------------------------------------------------------
    uint256 public constant LATE_PENALTY_BPS_PER_DAY = 500;
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant MAX_PLATFORM_FEE_BPS = 1_000; // 10% cap
    uint256 public constant REVIEW_TIMEOUT = 7 days;      // employer review window
    uint256 public constant ABANDON_GRACE = 7 days;       // after deadline, no submission
    uint256 public constant MAX_PAGE_SIZE = 50;

    // ------------------------------------------------------------------
    // State
    // ------------------------------------------------------------------
    address public owner;
    address public pendingOwner;
    uint256 public platformFeeBps;   // taken from the freelancer's payout
    uint256 public platformFees;     // accrued, withdrawable by owner
    bool private locked;

    enum Status {
        Open,
        InProgress,
        Submitted,
        Disputed,
        Paid,
        Cancelled
    }

    struct FreelancerProfile {
        uint256 id;
        string name;
        address wallet;
        uint8 experienceYears;
        bool isAvailableHire;
        uint256 hourlyRateInWei;
    }

    struct EmployerProfile {
        uint256 id;
        string name;
        bool isHiring;
        address wallet;
    }

    struct CreateJobListingInput {
        string title;
        string description;
        uint256 durationInSeconds; // time allowed AFTER the freelancer is hired
        uint256 fixedPriceInWei;
    }

    struct JobListing {
        uint256 id;
        string title;
        string description;
        uint256 durationInSeconds;
        uint256 deadlineTimestamp; // set when the freelancer is hired
        uint256 submittedAt;
        uint256 fixedPriceInWei;
        uint256 hiredFreelancerId;
        Status status;
    }

    FreelancerProfile[] private freelancerProfiles;
    EmployerProfile[] private employerProfiles;

    mapping(uint256 => JobListing[]) private jobsByEmployer;
    mapping(uint256 => uint256) public openJobCount; // employerId => open jobs

    mapping(uint256 => address) public freelancerIdToAddress;
    mapping(uint256 => address) public employerIdToAddress;
    mapping(address => uint256) public freelancerIdByAddress;
    mapping(address => uint256) public employerIdByAddress;
    mapping(address => bool) public freelancerRegistered;
    mapping(address => bool) public employerRegistered;

    // employerId => jobId => freelancerId => applied
    mapping(uint256 => mapping(uint256 => mapping(uint256 => bool))) public hasApplied;

    // Pull-payment balances (freelancer payouts and employer refunds)
    mapping(address => uint256) public pendingWithdrawals;

    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------
    event FreelancerProfileRegistered(uint256 indexed freelancerId, address indexed caller);
    event EmployerProfileRegistered(uint256 indexed employerId, address indexed caller);
    event JobCreated(uint256 indexed employerId, uint256 indexed jobId, uint256 price, uint256 durationInSeconds);
    event JobCancelled(uint256 indexed employerId, uint256 indexed jobId);
    event JobApplied(uint256 indexed employerId, uint256 indexed jobId, uint256 indexed freelancerId);
    event FreelancerHired(uint256 indexed employerId, uint256 indexed jobId, uint256 indexed freelancerId, uint256 deadline);
    event WorkSubmitted(uint256 indexed employerId, uint256 indexed jobId, uint256 submittedAt);
    event JobDisputed(uint256 indexed employerId, uint256 indexed jobId, address indexed raisedBy);
    event JobPaid(uint256 indexed employerId, uint256 indexed jobId, uint256 toFreelancer, uint256 refundedToEmployer, uint256 fee);
    event Withdrawn(address indexed account, uint256 amount);
    event PlatformFeeUpdated(uint256 newFeeBps);
    event PlatformFeesWithdrawn(address indexed to, uint256 amount);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // ------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------
    error Freelancer_AlreadyRegistered(address caller);
    error Freelancer_EmptyName();
    error Freelancer_InvalidJobInput();
    error Freelancer_IncorrectjobCreationFee(uint256 expectedFee, uint256 actualFee);
    error Freelancer_JobNotInStatus(uint256 jobId, Status current);
    error Freelancer_UnauthorizedEmployer(uint256 employerId, address caller);
    error Freelancer_UnauthorizedFreelancer(uint256 freelancerId, address caller);
    error Freelancer_InvalidJobId(uint256 employerId, uint256 jobId);
    error Freelancer_FreelancerUnavailable(uint256 freelancerId);
    error Freelancer_NotApplied(uint256 freelancerId, uint256 jobId);
    error Freelancer_AlreadyApplied(uint256 freelancerId, uint256 jobId);
    error Freelancer_TooEarly(uint256 availableAt);
    error Freelancer_NothingToWithdraw();
    error Freelancer_TransferFailed(address to, uint256 amount);
    error Freelancer_NotAuthorisedOwner();
    error Freelancer_NotPendingOwner();
    error Freelancer_InvalidAddress();
    error Freelancer_FeeTooHigh(uint256 feeBps);
    error Freelancer_InvalidShare(uint256 shareBps);
    error Freelancer_Reentrancy();

    // ------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------
    constructor(address _initialOwner)  {
        if (_initialOwner == address(0)) revert Freelancer_InvalidAddress();
        owner = _initialOwner;
        emit OwnershipTransferred(address(0), _initialOwner);
    }

    // ------------------------------------------------------------------
    // Modifiers
    // ------------------------------------------------------------------
    modifier nonReentrant() {
        if (locked) revert Freelancer_Reentrancy();
        locked = true;
        _;
        locked = false;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert Freelancer_NotAuthorisedOwner();
        _;
    }

    modifier onlyAuthorizedEmployer(uint256 employerId) {
        address employer = employerIdToAddress[employerId];
        if (employer == address(0) || employer != msg.sender) {
            revert Freelancer_UnauthorizedEmployer(employerId, msg.sender);
        }
        _;
    }

    modifier onlyAuthorizedFreelancer(uint256 freelancerId) {
        address f = freelancerIdToAddress[freelancerId];
        if (f == address(0) || f != msg.sender) {
            revert Freelancer_UnauthorizedFreelancer(freelancerId, msg.sender);
        }
        _;
    }

    modifier validateJobId(uint256 employerId, uint256 jobId) {
        if (jobId >= jobsByEmployer[employerId].length) {
            revert Freelancer_InvalidJobId(employerId, jobId);
        }
        _;
    }

    // ------------------------------------------------------------------
    // Registration
    // ------------------------------------------------------------------
    function getNumberOfRegisteredFreeLancers() public view returns (uint256) {
        return freelancerProfiles.length;
    }

    function getNumberOfRegisteredEmployers() public view returns (uint256) {
        return employerProfiles.length;
    }

    function registerFreelancerProfile(
        string calldata name,
        uint8 experienceYears,
        uint256 hourlyRateInWei
    ) external {
        if (freelancerRegistered[msg.sender]) revert Freelancer_AlreadyRegistered(msg.sender);
        if (bytes(name).length == 0) revert Freelancer_EmptyName();

        uint256 freelancerId = freelancerProfiles.length;

        freelancerProfiles.push(
            FreelancerProfile({
                id: freelancerId,
                name: name,
                wallet: msg.sender,
                experienceYears: experienceYears,
                isAvailableHire: true,
                hourlyRateInWei: hourlyRateInWei
            })
        );

        freelancerIdToAddress[freelancerId] = msg.sender;
        freelancerIdByAddress[msg.sender] = freelancerId;
        freelancerRegistered[msg.sender] = true;

        emit FreelancerProfileRegistered(freelancerId, msg.sender);
    }

    function registerEmployerProfile(string calldata name) external {
        if (employerRegistered[msg.sender]) revert Freelancer_AlreadyRegistered(msg.sender);
        if (bytes(name).length == 0) revert Freelancer_EmptyName();

        uint256 employerId = employerProfiles.length;

        employerProfiles.push(
            EmployerProfile({id: employerId, name: name, isHiring: false, wallet: msg.sender})
        );

        employerIdToAddress[employerId] = msg.sender;
        employerIdByAddress[msg.sender] = employerId;
        employerRegistered[msg.sender] = true;

        emit EmployerProfileRegistered(employerId, msg.sender);
    }

    // ------------------------------------------------------------------
    // Paginated views
    // ------------------------------------------------------------------
    function getFreelancerProfile(uint256 freelancerId) external view returns (FreelancerProfile memory) {
        return freelancerProfiles[freelancerId];
    }

    function getEmployerProfile(uint256 employerId) external view returns (EmployerProfile memory) {
        return employerProfiles[employerId];
    }

    function getFreelancerProfiles(uint256 offset, uint256 limit)
        external
        view
        returns (FreelancerProfile[] memory page)
    {
        uint256 total = freelancerProfiles.length;
        if (offset >= total) return new FreelancerProfile[](0);
        if (limit > MAX_PAGE_SIZE) limit = MAX_PAGE_SIZE;
        uint256 end = offset + limit;
        if (end > total) end = total;

        page = new FreelancerProfile[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            page[i - offset] = freelancerProfiles[i];
        }
    }

    function getNumberOfCreatedJobList(uint256 employerId) public view returns (uint256) {
        return jobsByEmployer[employerId].length;
    }

    function getJob(uint256 employerId, uint256 jobId)
        external
        view
        validateJobId(employerId, jobId)
        returns (JobListing memory)
    {
        return jobsByEmployer[employerId][jobId];
    }

    function getJobList(uint256 employerId, uint256 offset, uint256 limit)
        external
        view
        returns (JobListing[] memory page)
    {
        JobListing[] storage jobs = jobsByEmployer[employerId];
        uint256 total = jobs.length;
        if (offset >= total) return new JobListing[](0);
        if (limit > MAX_PAGE_SIZE) limit = MAX_PAGE_SIZE;
        uint256 end = offset + limit;
        if (end > total) end = total;

        page = new JobListing[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            page[i - offset] = jobs[i];
        }
    }

    // ------------------------------------------------------------------
    // Job lifecycle
    // ------------------------------------------------------------------
    function createjobListing(uint256 employerId, CreateJobListingInput calldata input)
        external
        payable
        onlyAuthorizedEmployer(employerId)
    {
        if (
            bytes(input.title).length == 0 ||
            input.fixedPriceInWei == 0 ||
            input.durationInSeconds == 0
        ) revert Freelancer_InvalidJobInput();

        if (msg.value != input.fixedPriceInWei) {
            revert Freelancer_IncorrectjobCreationFee(input.fixedPriceInWei, msg.value);
        }

        uint256 jobId = jobsByEmployer[employerId].length;

        jobsByEmployer[employerId].push(
            JobListing({
                id: jobId,
                title: input.title,
                description: input.description,
                durationInSeconds: input.durationInSeconds,
                deadlineTimestamp: 0,
                submittedAt: 0,
                fixedPriceInWei: input.fixedPriceInWei,
                hiredFreelancerId: 0,
                status: Status.Open
            })
        );

        openJobCount[employerId] += 1;
        employerProfiles[employerId].isHiring = true;

        emit JobCreated(employerId, jobId, input.fixedPriceInWei, input.durationInSeconds);
    }

    /// @notice Employer cancels a job nobody has been hired for. Escrow is refunded.
    function cancelJob(uint256 employerId, uint256 jobId)
        external
        onlyAuthorizedEmployer(employerId)
        validateJobId(employerId, jobId)
    {
        JobListing storage job = jobsByEmployer[employerId][jobId];
        if (job.status != Status.Open) revert Freelancer_JobNotInStatus(jobId, job.status);

        job.status = Status.Cancelled;
        _decrementOpen(employerId);
        pendingWithdrawals[msg.sender] += job.fixedPriceInWei;

        emit JobCancelled(employerId, jobId);
    }

    /// @notice Freelancer signals consent to be hired for this job.
    function applyForJob(uint256 freelancerId, uint256 employerId, uint256 jobId)
        external
        onlyAuthorizedFreelancer(freelancerId)
        validateJobId(employerId, jobId)
    {
        JobListing storage job = jobsByEmployer[employerId][jobId];
        if (job.status != Status.Open) revert Freelancer_JobNotInStatus(jobId, job.status);
        if (hasApplied[employerId][jobId][freelancerId]) {
            revert Freelancer_AlreadyApplied(freelancerId, jobId);
        }

        hasApplied[employerId][jobId][freelancerId] = true;
        emit JobApplied(employerId, jobId, freelancerId);
    }

    function hireFreelancer(uint256 employerId, uint256 freelancerId, uint256 jobId)
        external
        onlyAuthorizedEmployer(employerId)
        validateJobId(employerId, jobId)
    {
        if (freelancerIdToAddress[freelancerId] == address(0)) {
            revert Freelancer_UnauthorizedFreelancer(freelancerId, msg.sender);
        }

        JobListing storage job = jobsByEmployer[employerId][jobId];
        if (job.status != Status.Open) revert Freelancer_JobNotInStatus(jobId, job.status);
        if (!hasApplied[employerId][jobId][freelancerId]) {
            revert Freelancer_NotApplied(freelancerId, jobId);
        }

        FreelancerProfile storage profile = freelancerProfiles[freelancerId];
        if (!profile.isAvailableHire) revert Freelancer_FreelancerUnavailable(freelancerId);

        profile.isAvailableHire = false;
        job.hiredFreelancerId = freelancerId;
        job.status = Status.InProgress;
        job.deadlineTimestamp = block.timestamp + job.durationInSeconds;
        _decrementOpen(employerId);

        emit FreelancerHired(employerId, jobId, freelancerId, job.deadlineTimestamp);
    }

    /// @notice Hired freelancer marks the work as delivered. Lateness is measured here.
    function submitWork(uint256 employerId, uint256 jobId)
        external
        validateJobId(employerId, jobId)
    {
        JobListing storage job = jobsByEmployer[employerId][jobId];
        if (job.status != Status.InProgress) revert Freelancer_JobNotInStatus(jobId, job.status);

        if (freelancerIdToAddress[job.hiredFreelancerId] != msg.sender) {
            revert Freelancer_UnauthorizedFreelancer(job.hiredFreelancerId, msg.sender);
        }

        job.submittedAt = block.timestamp;
        job.status = Status.Submitted;

        emit WorkSubmitted(employerId, jobId, block.timestamp);
    }

    /// @notice Employer approves the submitted work.
    function releaseEscrowPayment(uint256 employerId, uint256 jobId)
        external
        onlyAuthorizedEmployer(employerId)
        validateJobId(employerId, jobId)
    {
        JobListing storage job = jobsByEmployer[employerId][jobId];
        if (job.status != Status.Submitted) revert Freelancer_JobNotInStatus(jobId, job.status);

        uint256 pay = _calculatePayment(job.fixedPriceInWei, job.deadlineTimestamp, job.submittedAt);
        _payout(employerId, job, pay);
    }

    /// @notice If the employer ignores a submission for REVIEW_TIMEOUT, the freelancer can claim.
    function claimAfterTimeout(uint256 employerId, uint256 jobId)
        external
        validateJobId(employerId, jobId)
    {
        JobListing storage job = jobsByEmployer[employerId][jobId];
        if (job.status != Status.Submitted) revert Freelancer_JobNotInStatus(jobId, job.status);

        if (freelancerIdToAddress[job.hiredFreelancerId] != msg.sender) {
            revert Freelancer_UnauthorizedFreelancer(job.hiredFreelancerId, msg.sender);
        }

        uint256 availableAt = job.submittedAt + REVIEW_TIMEOUT;
        if (block.timestamp < availableAt) revert Freelancer_TooEarly(availableAt);

        uint256 pay = _calculatePayment(job.fixedPriceInWei, job.deadlineTimestamp, job.submittedAt);
        _payout(employerId, job, pay);
    }

    /// @notice Employer reclaims escrow if the freelancer never submitted, well past the deadline.
    function cancelStalledJob(uint256 employerId, uint256 jobId)
        external
        onlyAuthorizedEmployer(employerId)
        validateJobId(employerId, jobId)
    {
        JobListing storage job = jobsByEmployer[employerId][jobId];
        if (job.status != Status.InProgress) revert Freelancer_JobNotInStatus(jobId, job.status);

        uint256 availableAt = job.deadlineTimestamp + ABANDON_GRACE;
        if (block.timestamp < availableAt) revert Freelancer_TooEarly(availableAt);

        job.status = Status.Cancelled;
        freelancerProfiles[job.hiredFreelancerId].isAvailableHire = true;
        pendingWithdrawals[msg.sender] += job.fixedPriceInWei;

        emit JobCancelled(employerId, jobId);
    }

    /// @notice Either party can freeze a job and ask the owner (arbiter) to resolve it.
    function raiseDispute(uint256 employerId, uint256 jobId)
        external
        validateJobId(employerId, jobId)
    {
        JobListing storage job = jobsByEmployer[employerId][jobId];
        if (job.status != Status.InProgress && job.status != Status.Submitted) {
            revert Freelancer_JobNotInStatus(jobId, job.status);
        }

        bool isEmployer = employerIdToAddress[employerId] == msg.sender;
        bool isFreelancer = freelancerIdToAddress[job.hiredFreelancerId] == msg.sender;
        if (!isEmployer && !isFreelancer) {
            revert Freelancer_UnauthorizedEmployer(employerId, msg.sender);
        }

        job.status = Status.Disputed;
        emit JobDisputed(employerId, jobId, msg.sender);
    }

    /// @notice Owner splits escrow. freelancerShareBps of the price goes to the freelancer.
    function resolveDispute(uint256 employerId, uint256 jobId, uint256 freelancerShareBps)
        external
        onlyOwner
        validateJobId(employerId, jobId)
    {
        if (freelancerShareBps > BPS_DENOMINATOR) revert Freelancer_InvalidShare(freelancerShareBps);

        JobListing storage job = jobsByEmployer[employerId][jobId];
        if (job.status != Status.Disputed) revert Freelancer_JobNotInStatus(jobId, job.status);

        uint256 toFreelancer = (job.fixedPriceInWei * freelancerShareBps) / BPS_DENOMINATOR;
        _payout(employerId, job, toFreelancer);
    }

    // ------------------------------------------------------------------
    // Withdrawals (pull payments)
    // ------------------------------------------------------------------
    function withdraw() external nonReentrant {
        uint256 amount = pendingWithdrawals[msg.sender];
        if (amount == 0) revert Freelancer_NothingToWithdraw();

        pendingWithdrawals[msg.sender] = 0;
        _sendEther(msg.sender, amount);

        emit Withdrawn(msg.sender, amount);
    }

    // ------------------------------------------------------------------
    // Owner functions
    // ------------------------------------------------------------------
    function setPlatformFee(uint256 newFeeBps) external onlyOwner {
        if (newFeeBps > MAX_PLATFORM_FEE_BPS) revert Freelancer_FeeTooHigh(newFeeBps);
        platformFeeBps = newFeeBps;
        emit PlatformFeeUpdated(newFeeBps);
    }

    function withdrawPlatformFees(address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert Freelancer_InvalidAddress();
        uint256 amount = platformFees;
        if (amount == 0) revert Freelancer_NothingToWithdraw();

        platformFees = 0;
        _sendEther(to, amount);

        emit PlatformFeesWithdrawn(to, amount);
    }

    /// @notice Step 1 of a two-step ownership transfer.
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert Freelancer_InvalidAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    /// @notice Step 2: the new owner accepts.
    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert Freelancer_NotPendingOwner();
        address old = owner;
        owner = msg.sender;
        pendingOwner = address(0);
        emit OwnershipTransferred(old, msg.sender);
    }

    // ------------------------------------------------------------------
    // Internal helpers
    // ------------------------------------------------------------------
    function _decrementOpen(uint256 employerId) internal {
        uint256 count = openJobCount[employerId] - 1;
        openJobCount[employerId] = count;
        if (count == 0) employerProfiles[employerId].isHiring = false;
    }

    /// @dev Splits the job's escrow: `toFreelancer` (minus platform fee) to the freelancer,
    ///      the remainder back to the employer. Effects only; funds are pulled via withdraw().
    function _payout(uint256 employerId, JobListing storage job, uint256 toFreelancer) internal {
        uint256 price = job.fixedPriceInWei;
        uint256 fee = (toFreelancer * platformFeeBps) / BPS_DENOMINATOR;
        uint256 refund = price - toFreelancer;

        job.status = Status.Paid;
        platformFees += fee;

        pendingWithdrawals[freelancerIdToAddress[job.hiredFreelancerId]] += toFreelancer - fee;
        if (refund > 0) {
            pendingWithdrawals[employerIdToAddress[employerId]] += refund;
        }

        freelancerProfiles[job.hiredFreelancerId].isAvailableHire = true;

        emit JobPaid(employerId, job.id, toFreelancer - fee, refund, fee);
    }

    function _sendEther(address to, uint256 amount) internal {
        (bool success, ) = to.call{value: amount}("");
        if (!success) revert Freelancer_TransferFailed(to, amount);
    }

    /// @dev Lateness is measured from submission time, not from when the employer approves.
    function _calculatePayment(uint256 amount, uint256 deadline, uint256 submittedAt)
        internal
        pure
        returns (uint256)
    {
        if (submittedAt <= deadline) return amount;

        uint256 delayInDays = (submittedAt - deadline + 1 days - 1) / 1 days;
        uint256 deductionBps = delayInDays * LATE_PENALTY_BPS_PER_DAY;
        if (deductionBps > BPS_DENOMINATOR) deductionBps = BPS_DENOMINATOR;

        return amount - (amount * deductionBps) / BPS_DENOMINATOR;
    }
}
