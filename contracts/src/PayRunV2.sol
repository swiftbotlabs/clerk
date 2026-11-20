// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20, IAgentIdentity} from "./PayRun.sol";

/// @title PayRunV2: PayRun plus a payee-change hold.
/// @notice Everything PayRun does (staging-only session keys with caps and expiry, on-chain Confirmation of Payee against
/// the ERC-8004 registry, pay-once invoices, owner-only all-or-nothing execution, 7-day run TTL), plus:
///
/// Payee-change hold. The contract remembers, per vendor identity, the wallet it TRUSTS (one the owner confirmed, or one
/// that was paid after its hold ran out). When the registry shows any other wallet (a brand-new vendor, or a vendor whose
/// registered wallet changed), the first time the contract sees it a hold starts and payments to it are blocked until:
///   - the hold window passes (owner-set, 1 hour .. 3 days, default 24 hours), or
///   - the owner re-confirms that exact wallet (`confirmPayee`), which releases it early and is logged on chain.
/// Rules that a plain "new payee delay" does not have:
///   - Trust is never restored by changing back: A -> B -> A withdraws trust in A at the first change and restarts the
///     hold on every change the contract sees. `changes` only ever goes up.
///   - A line staged while its payee was still on hold can't be paid by waiting: it needs the owner's confirmation
///     ("new bank details, pay today" is exactly the redirect pattern).
///   - A run whose payee changed after staging (registry now differs, or any change was seen since) is refused and
///     closed at execute, and the change is recorded, so the clerk must restage against the new (held) wallet.
///   - Only the owner (the smart account) can confirm; the clerk's session key can stage and observe, nothing else.
/// Blocked payments do not revert: `execute` returns false and emits `PaymentBlocked`, so the block and the hold it
/// started stay on chain as an audit trail.
contract PayRunV2 {
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

    /// Per vendor identity. Invariant: trusted != 0 implies pending == 0.
    struct Payee {
        address trusted;    // confirmed by the owner, or paid after its hold ran out; 0 = none
        address pending;    // the registered wallet seen last, not trusted yet; 0 = none
        uint64 seenAt;      // when `pending` was first seen
        uint64 releaseAt;   // when the hold on `pending` ends by time (fixed when the hold starts)
        uint32 changes;     // registry changes seen for this vendor (new vendor = 1); never goes down
        bool confirmed;     // `trusted` was confirmed by the owner (not only paid after its hold ran out)
    }

    struct LineMeta {
        uint32 epoch;       // Payee.changes when the line was staged
        bool stagedOnHold;  // the payee was still on hold at staging: only an owner confirmation releases this line
    }

    enum PayeeState { None, Trusted, Held, Released }
    uint8 public constant BLOCK_HOLD = 1;                  // payee still inside its hold window
    uint8 public constant BLOCK_NEEDS_CONFIRMATION = 2;    // staged during the hold: owner must confirm the payee
    uint8 public constant BLOCK_CHANGED_SINCE_STAGING = 3; // payee changed after staging: run refused and closed

    uint256 public constant MAX_LINES = 25;
    uint64 public constant RUN_TTL = 7 days;   // a staged run older than this can't be executed (stale approvals)
    uint64 public constant MIN_HOLD = 1 hours;
    uint64 public constant MAX_HOLD = 3 days;  // below RUN_TTL, so a staged run can always outlive a hold
    uint64 public constant DEFAULT_HOLD = 24 hours;

    IERC20 public immutable token;
    IAgentIdentity public immutable registry;
    address public owner;
    address public treasury;                   // pays the invoices (gives this contract an allowance)
    uint64 public holdWindow = DEFAULT_HOLD;

    mapping(address => Session) public sessions;
    mapping(uint256 => Run) public runs;
    mapping(uint256 => mapping(uint256 => Line)) internal _lines;
    mapping(uint256 => mapping(uint256 => LineMeta)) public lineMeta;
    mapping(uint256 => Payee) public payees;           // agentId -> payee hold state
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
    // payee-change hold
    event HoldWindowChanged(uint64 previous, uint64 next);
    event PayeeChanged(uint256 indexed agentId, address indexed from, address indexed to, uint32 changes);
    event HoldStarted(uint256 indexed agentId, address indexed wallet, uint64 releaseAt);
    event StagedOnHold(uint256 indexed runId, uint256 line, uint256 indexed agentId, address payee, uint64 releaseAt);
    event PaymentBlocked(uint256 indexed runId, uint256 line, uint256 indexed agentId, address payee, uint8 reason, uint64 releaseAt);
    /// Audit entry for an early release: who confirmed which wallet, and when the hold would have ended by itself.
    event PayeeConfirmed(uint256 indexed agentId, address indexed wallet, address indexed by, uint64 releaseAt);
    event HoldReleased(uint256 indexed agentId, address indexed wallet, bool early);

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
    error BadHoldWindow(uint64 window);
    error ConfirmMismatch(uint256 agentId, address wallet, address registered);
    error AlreadyTrusted(uint256 agentId, address wallet);

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
        emit HoldWindowChanged(0, DEFAULT_HOLD);
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

    /// @notice Set the hold for wallets seen from now on (1 hour .. 3 days). Holds already running keep their end time.
    function setHoldWindow(uint64 window) external onlyOwner {
        if (window < MIN_HOLD || window > MAX_HOLD) revert BadHoldWindow(window);
        emit HoldWindowChanged(holdWindow, window);
        holdWindow = window;
    }

    /// @notice The owner re-confirms a vendor's wallet (e.g. after calling the vendor on a known number). Releases the
    /// hold early. `wallet` must be the vendor's registered wallet right now. Works for a vendor not seen yet (onboarding).
    function confirmPayee(uint256 agentId, address wallet) external onlyOwner {
        address reg = _observe(agentId);
        if (wallet == address(0) || reg != wallet) revert ConfirmMismatch(agentId, wallet, reg);
        Payee storage p = payees[agentId];
        if (p.trusted == wallet && p.confirmed) revert AlreadyTrusted(agentId, wallet);
        uint64 rel = p.releaseAt;
        p.trusted = wallet;
        p.pending = address(0);
        p.confirmed = true;
        emit PayeeConfirmed(agentId, wallet, msg.sender, rel);
        emit HoldReleased(agentId, wallet, true);
    }

    // ---------------------------------------------------------------- anyone

    /// @notice Record the vendor's registered wallet now (a watcher can call this so a change starts its hold at once).
    function observePayee(uint256 agentId) external returns (address registered) {
        return _observe(agentId);
    }

    // ---------------------------------------------------------------- the clerk's only power

    /// @notice Stage a pay run. Only an active session key; caps, expiry and on-chain Confirmation of Payee apply.
    /// A payee on hold can be staged (so the hold is recorded and shown), but the run won't pay until it is released.
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
            address reg = _observe(l.payeeAgentId);
            if (l.payee == address(0) || reg != l.payee) revert PayeeNotRegistered(i, l.payeeAgentId, l.payee, reg);
            uint256 paid = paidInRun[l.invoiceHash];
            if (paid != 0) revert AlreadyPaid(i, l.invoiceHash, paid);
            uint256 open = stagedInRun[l.invoiceHash];
            if (open != 0) revert AlreadyStaged(i, l.invoiceHash, open);   // also catches a duplicate inside this run
            stagedInRun[l.invoiceHash] = runId;
            _lines[runId][i] = l;
            Payee storage p = payees[l.payeeAgentId];
            bool onHold = !_released(p, l.payee);
            lineMeta[runId][i] = LineMeta({epoch: p.changes, stagedOnHold: onHold});
            if (onHold) emit StagedOnHold(runId, i, l.payeeAgentId, l.payee, p.releaseAt);
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

    /// @notice Pay a staged run from the treasury, all or nothing. Every payee is read from the registry again now.
    /// Returns false (and pays nothing) when a line is blocked: a payee on hold or needing confirmation leaves the run
    /// staged; a payee that changed since staging closes the run as Rejected. Each blocked line emits PaymentBlocked.
    function execute(uint256 runId) external onlyOwner nonReentrant returns (bool paid) {
        Run storage r = runs[runId];
        if (r.status != Status.Staged) revert NotStaged(runId);
        if (block.timestamp > r.stagedAt + RUN_TTL) revert RunStale(runId);
        uint256 n = r.lineCount;
        bool blocked;
        bool changed;
        for (uint256 i = 0; i < n; i++) {
            Line storage l = _lines[runId][i];
            address reg = _observe(l.payeeAgentId);
            Payee storage p = payees[l.payeeAgentId];
            LineMeta memory m = lineMeta[runId][i];
            uint8 reason;
            if (reg != l.payee || p.changes != m.epoch) reason = BLOCK_CHANGED_SINCE_STAGING;
            else if (!_released(p, l.payee)) reason = BLOCK_HOLD;
            else if (m.stagedOnHold && !(p.confirmed && p.trusted == l.payee)) reason = BLOCK_NEEDS_CONFIRMATION;
            if (reason != 0) {
                blocked = true;
                if (reason == BLOCK_CHANGED_SINCE_STAGING) changed = true;
                emit PaymentBlocked(runId, i, l.payeeAgentId, l.payee, reason, p.releaseAt);
            }
        }
        if (blocked) {
            if (changed) _close(runId, r, "payee changed since staging");
            return false;
        }
        r.status = Status.Executed;
        for (uint256 i = 0; i < n; i++) {
            Line storage l = _lines[runId][i];
            Payee storage p = payees[l.payeeAgentId];
            if (p.trusted != l.payee) {        // released by time and now paid: it becomes the trusted wallet
                p.trusted = l.payee;
                p.pending = address(0);
                emit HoldReleased(l.payeeAgentId, l.payee, false);
            }
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
        return true;
    }

    /// @notice Reject a staged run; its invoices can be staged again.
    function reject(uint256 runId, string calldata reason) external onlyOwner {
        Run storage r = runs[runId];
        if (r.status != Status.Staged) revert NotStaged(runId);
        _close(runId, r, reason);
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

    /// @notice A vendor's hold state as a payment made now would see it (an unseen change counts as a hold starting now).
    function payeeStatus(uint256 agentId) public view
        returns (PayeeState state, address wallet, uint64 releaseAt, uint32 changes)
    {
        Payee memory p = _peek(agentId);
        wallet = p.trusted != address(0) ? p.trusted : p.pending;
        releaseAt = p.releaseAt;
        changes = p.changes;
        if (wallet == address(0)) state = PayeeState.None;
        else if (p.trusted != address(0)) state = PayeeState.Trusted;
        else if (block.timestamp >= p.releaseAt) state = PayeeState.Released;
        else state = PayeeState.Held;
    }

    /// @notice Would `execute(runId)` pay now? If not: the first blocked line, the reason (BLOCK_*) and the hold's end.
    function canExecute(uint256 runId) external view returns (bool ok, uint256 line, uint8 reason, uint64 releaseAt) {
        Run storage r = runs[runId];
        if (r.status != Status.Staged || block.timestamp > r.stagedAt + RUN_TTL) return (false, 0, 0, 0);
        uint256 n = r.lineCount;
        for (uint256 i = 0; i < n; i++) {
            Line storage l = _lines[runId][i];
            Payee memory p = _peek(l.payeeAgentId);
            LineMeta memory m = lineMeta[runId][i];
            address reg = registry.getAgentWallet(l.payeeAgentId);
            if (reg != l.payee || p.changes != m.epoch) return (false, i, BLOCK_CHANGED_SINCE_STAGING, p.releaseAt);
            if (!_releasedMem(p, l.payee)) return (false, i, BLOCK_HOLD, p.releaseAt);
            if (m.stagedOnHold && !(p.confirmed && p.trusted == l.payee)) return (false, i, BLOCK_NEEDS_CONFIRMATION, p.releaseAt);
        }
        return (true, 0, 0, 0);
    }

    // ---------------------------------------------------------------- internals

    /// Read the registered wallet and record a change if it differs from what we know. Any change withdraws trust and
    /// (for a non-zero wallet) starts a fresh hold; nothing ever turns a wallet back into "known" except a confirmation
    /// or a payment after the hold ran out.
    function _observe(uint256 agentId) internal returns (address reg) {
        reg = registry.getAgentWallet(agentId);
        Payee storage p = payees[agentId];
        address from;
        if (p.trusted != address(0)) {
            if (reg == p.trusted) return reg;
            from = p.trusted;
            p.trusted = address(0);
            p.confirmed = false;
        } else {
            if (reg == p.pending) return reg;
            from = p.pending;
        }
        p.changes += 1;
        p.pending = reg;
        if (reg == address(0)) {
            p.seenAt = 0;
            p.releaseAt = 0;
            emit PayeeChanged(agentId, from, reg, p.changes);
            return reg;
        }
        uint64 rel = uint64(block.timestamp) + holdWindow;
        p.seenAt = uint64(block.timestamp);
        p.releaseAt = rel;
        emit PayeeChanged(agentId, from, reg, p.changes);
        emit HoldStarted(agentId, reg, rel);
    }

    /// The state `_observe` would leave, without writing it.
    function _peek(uint256 agentId) internal view returns (Payee memory p) {
        p = payees[agentId];
        address reg = registry.getAgentWallet(agentId);
        if (p.trusted != address(0) ? reg == p.trusted : reg == p.pending) return p;
        p.trusted = address(0);
        p.confirmed = false;
        p.changes += 1;
        p.pending = reg;
        p.seenAt = reg == address(0) ? 0 : uint64(block.timestamp);
        p.releaseAt = reg == address(0) ? 0 : uint64(block.timestamp) + holdWindow;
    }

    function _released(Payee storage p, address wallet) internal view returns (bool) {
        return wallet != address(0) && (wallet == p.trusted || (wallet == p.pending && block.timestamp >= p.releaseAt));
    }

    function _releasedMem(Payee memory p, address wallet) internal view returns (bool) {
        return wallet != address(0) && (wallet == p.trusted || (wallet == p.pending && block.timestamp >= p.releaseAt));
    }

    function _close(uint256 runId, Run storage r, string memory reason) internal {
        r.status = Status.Rejected;
        uint256 n = r.lineCount;
        for (uint256 i = 0; i < n; i++) delete stagedInRun[_lines[runId][i].invoiceHash];
        emit Rejected(runId, reason);
    }
}
