// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal ERC-20 surface (tUSD8 on Aevum testnet: 6 decimals, USDC-style).
interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice The ERC-8004 identity registry on Aevum testnet (0xF45E7f39Caba1d2055f613970575a7e7069636Be).
/// `getAgentWallet(agentId)` is the wallet the vendor registered for its identity.
interface IAgentIdentity {
    function getAgentWallet(uint256 agentId) external view returns (address);
}

/// @title PayRun: accounts payable where the AI clerk can only propose, and only to registered payees.
/// @notice An AI clerk holds a scoped session key. The key can only STAGE a pay run: under a per-run cap and a
/// per-day cap, before its expiry, to payees whose wallet is the one registered for their ERC-8004 identity
/// (Confirmation of Payee on chain). It can never move money. The owner reviews a staged run and executes it with
/// one call; execution re-checks every payee against the registry and pays each invoice at most once, ever.
contract PayRun {
    struct Session {
        uint64 expiry;      // unix seconds; the key is dead after this
        uint64 day;         // day index (block.timestamp / 1 days) of `stagedToday`
        uint128 perRunCap;  // max total of one staged run (token units)
        uint128 perDayCap;  // max total staged per day by this key
        uint128 stagedToday;
        bool revoked;
    }

    struct Line {
        uint256 payeeAgentId; // ERC-8004 identity of the vendor
        address payee;        // must equal registry.getAgentWallet(payeeAgentId)
        uint128 amount;       // token units (tUSD8: 6 decimals)
        bytes32 invoiceHash;  // keccak256 of the source invoice document: pays once, ever
        bytes32 invoiceRef;   // the invoice number as printed (left-aligned bytes)
    }

    enum Status { None, Staged, Executed, Rejected }

    struct Run {
        Status status;
        address stagedBy;
        uint64 stagedAt;
        uint128 total;
        uint32 lineCount;
    }

    uint256 public constant MAX_LINES = 25;
    uint64 public constant RUN_TTL = 7 days;   // a staged run older than this can't be executed (stale approvals)

    IERC20 public immutable token;
    IAgentIdentity public immutable registry;
    address public owner;
    address public treasury;                   // pays the invoices (gives this contract an allowance)

    mapping(address => Session) public sessions;
    mapping(uint256 => Run) public runs;
    mapping(uint256 => mapping(uint256 => Line)) internal _lines;
    mapping(bytes32 => uint256) public paidInRun;     // invoiceHash -> run that paid it (0 = unpaid)
    mapping(bytes32 => uint256) public stagedInRun;   // invoiceHash -> open staged run holding it (0 = none)
    uint256 public runCount;
    uint256 private _lock = 1;

    event OwnerChanged(address indexed owner);
    event TreasuryChanged(address indexed treasury);
    event SessionGranted(address indexed key, uint64 expiry, uint128 perRunCap, uint128 perDayCap);
    event SessionRevoked(address indexed key);
    event Staged(uint256 indexed runId, address indexed key, uint256 lines, uint256 total);
    event Rejected(uint256 indexed runId, string reason);
    event Paid(uint256 indexed runId, uint256 line, bytes32 indexed invoiceHash, bytes32 invoiceRef,
        uint256 indexed payeeAgentId, address payee, uint256 amount);
    event Executed(uint256 indexed runId, uint256 total);

    error NotOwner();
    error NoSession();
    error SessionExpired();
    error SessionRevokedErr();
    error BadLines();
    error RunCapExceeded(uint256 total, uint256 cap);
    error DayCapExceeded(uint256 stagedToday, uint256 cap);
    error PayeeNotRegistered(uint256 line, uint256 agentId, address payee, address registered);
    error ZeroAmount(uint256 line);
    error AlreadyPaid(uint256 line, bytes32 invoiceHash, uint256 runId);
    error AlreadyStaged(uint256 line, bytes32 invoiceHash, uint256 runId);
    error NotStaged(uint256 runId);
    error RunStale(uint256 runId);
    error TransferFailed(uint256 line);
    error Reentrancy();
    error BadSession();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier nonReentrant() {
        if (_lock != 1) revert Reentrancy();
        _lock = 2;
        _;
        _lock = 1;
    }

    constructor(IERC20 token_, IAgentIdentity registry_, address owner_, address treasury_) {
        token = token_;
        registry = registry_;
        owner = owner_;
        treasury = treasury_;
        emit OwnerChanged(owner_);
        emit TreasuryChanged(treasury_);
    }

    // ---------------------------------------------------------------- owner controls

    function setOwner(address next) external onlyOwner {
        owner = next;
        emit OwnerChanged(next);
    }

    function setTreasury(address next) external onlyOwner {
        treasury = next;
        emit TreasuryChanged(next);
    }

    /// @notice Give (or replace) a staging-only session key with caps and an expiry.
    function grantSession(address key, uint64 expiry, uint128 perRunCap, uint128 perDayCap) external onlyOwner {
        if (key == address(0) || expiry <= block.timestamp || perRunCap == 0 || perDayCap < perRunCap) revert BadSession();
        sessions[key] = Session({expiry: expiry, day: 0, perRunCap: perRunCap, perDayCap: perDayCap, stagedToday: 0, revoked: false});
        emit SessionGranted(key, expiry, perRunCap, perDayCap);
    }

    /// @notice Kill a session key at once. Runs it already staged stay for the owner to execute or reject.
    function revokeSession(address key) external onlyOwner {
        sessions[key].revoked = true;
        emit SessionRevoked(key);
    }

    // ---------------------------------------------------------------- the clerk's only power

    /// @notice Stage a pay run. Only an active session key; caps, expiry and on-chain Confirmation of Payee apply.
    function stage(Line[] calldata lines) external returns (uint256 runId) {
        Session storage s = sessions[msg.sender];
        if (s.expiry == 0) revert NoSession();
        if (s.revoked) revert SessionRevokedErr();
        if (block.timestamp >= s.expiry) revert SessionExpired();
        uint256 n = lines.length;
        if (n == 0 || n > MAX_LINES) revert BadLines();

        runId = ++runCount;
        uint256 total;
        for (uint256 i = 0; i < n; i++) {
            Line calldata l = lines[i];
            if (l.amount == 0) revert ZeroAmount(i);
            _checkPayee(i, l.payeeAgentId, l.payee);
            uint256 paid = paidInRun[l.invoiceHash];
            if (paid != 0) revert AlreadyPaid(i, l.invoiceHash, paid);
            uint256 open = stagedInRun[l.invoiceHash];
            if (open != 0) revert AlreadyStaged(i, l.invoiceHash, open);   // also catches a duplicate inside this run
            stagedInRun[l.invoiceHash] = runId;
            _lines[runId][i] = l;
            total += l.amount;
        }
        if (total > s.perRunCap) revert RunCapExceeded(total, s.perRunCap);
        uint64 today = uint64(block.timestamp / 1 days);
        if (s.day != today) {
            s.day = today;
            s.stagedToday = 0;
        }
        uint256 dayTotal = uint256(s.stagedToday) + total;
        if (dayTotal > s.perDayCap) revert DayCapExceeded(dayTotal, s.perDayCap);
        s.stagedToday = uint128(dayTotal);

        runs[runId] = Run({status: Status.Staged, stagedBy: msg.sender, stagedAt: uint64(block.timestamp),
            total: uint128(total), lineCount: uint32(n)});
        emit Staged(runId, msg.sender, n, total);
    }

    // ---------------------------------------------------------------- the owner's decision

    /// @notice Pay a staged run from the treasury. Every payee is checked against the registry again, now:
    /// if a vendor's registered wallet changed since staging, the whole run reverts (fail closed).
    function execute(uint256 runId) external onlyOwner nonReentrant {
        Run storage r = runs[runId];
        if (r.status != Status.Staged) revert NotStaged(runId);
        if (block.timestamp > r.stagedAt + RUN_TTL) revert RunStale(runId);
        r.status = Status.Executed;
        uint256 n = r.lineCount;
        for (uint256 i = 0; i < n; i++) {
            Line storage l = _lines[runId][i];
            _checkPayee(i, l.payeeAgentId, l.payee);
            paidInRun[l.invoiceHash] = runId;
            delete stagedInRun[l.invoiceHash];
        }
        address from = treasury;
        for (uint256 i = 0; i < n; i++) {
            Line storage l = _lines[runId][i];
            if (!token.transferFrom(from, l.payee, l.amount)) revert TransferFailed(i);
            emit Paid(runId, i, l.invoiceHash, l.invoiceRef, l.payeeAgentId, l.payee, l.amount);
        }
        emit Executed(runId, r.total);
    }

    /// @notice Reject a staged run; its invoices can be staged again.
    function reject(uint256 runId, string calldata reason) external onlyOwner {
        Run storage r = runs[runId];
        if (r.status != Status.Staged) revert NotStaged(runId);
        r.status = Status.Rejected;
        uint256 n = r.lineCount;
        for (uint256 i = 0; i < n; i++) delete stagedInRun[_lines[runId][i].invoiceHash];
        emit Rejected(runId, reason);
    }

    // ---------------------------------------------------------------- views

    function lineOf(uint256 runId, uint256 i) external view returns (Line memory) {
        return _lines[runId][i];
    }

    function linesOf(uint256 runId) external view returns (Line[] memory out) {
        uint256 n = runs[runId].lineCount;
        out = new Line[](n);
        for (uint256 i = 0; i < n; i++) out[i] = _lines[runId][i];
    }

    /// @notice What a key may still stage today (0 when expired or revoked).
    function headroom(address key) external view returns (uint256 perRun, uint256 today) {
        Session memory s = sessions[key];
        if (s.expiry == 0 || s.revoked || block.timestamp >= s.expiry) return (0, 0);
        uint256 used = s.day == uint64(block.timestamp / 1 days) ? s.stagedToday : 0;
        today = s.perDayCap - used;
        perRun = s.perRunCap < today ? s.perRunCap : today;
    }

    function _checkPayee(uint256 i, uint256 agentId, address payee) internal view {
        address registered = registry.getAgentWallet(agentId);
        if (payee == address(0) || registered != payee) revert PayeeNotRegistered(i, agentId, payee, registered);
    }
}
