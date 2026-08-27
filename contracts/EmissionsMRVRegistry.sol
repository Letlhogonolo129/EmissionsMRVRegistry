// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title  EmissionsMRVRegistry
 * @notice Reference EVM implementation of the permissioned MRV ledger specified in Part B.
 *
 * @dev DESIGN NOTE — why this is one contract and not four.
 *
 *      Part B specifies four cooperating Hyperledger Fabric chaincodes: an Emission
 *      Recording contract, a Verification and Attestation contract, a Control and
 *      Identity contract, and a Reporting and Audit Trail contract. On Fabric those
 *      are separate deployable units sharing a channel's world state. The EVM has no
 *      equivalent of shared world state: separate contracts would have to reach each
 *      other through external calls, each of which costs gas, widens the trust
 *      surface, and introduces re-entrancy considerations that add nothing to the
 *      MRV problem.
 *
 *      The four chaincodes are therefore implemented as four clearly demarcated
 *      modules within a single contract, marked MODULE 1 to MODULE 4 below. The
 *      logical separation Part B relies on — that no single party's action both
 *      submits and certifies a figure — is preserved through role modifiers and a
 *      separation-of-duties check, not through deployment boundaries.
 *
 *      Two further Fabric features have no EVM analogue and are deliberately not
 *      simulated: endorsement policies (multi-organisation signing of a single
 *      transaction) and channels (data partitioning). Their absence is discussed in
 *      the critical evaluation rather than papered over here.
 *
 * @dev IMMUTABILITY MODEL.
 *
 *      No function in this contract ever alters the substantive content of an
 *      emission record — the facility, category, quantity, period, evidence hash,
 *      submitter and submission timestamp are written once and never touched again.
 *      Only two things about a record can change after submission: its verification
 *      status, and the forward pointer set when a later record supersedes it.
 *      Corrections are new entries that reference the original, exactly as Part A
 *      requires: history is appended to, never rewritten.
 */
contract EmissionsMRVRegistry {
    // ---------------------------------------------------------------------
    // TYPES
    // ---------------------------------------------------------------------

    /// @notice Distinguishes a human signer from a provisioned sensor/meter key.
    /// Part B requires readings to be traceable to a specific calibrated device or
    /// a specific named individual, not merely to "the manufacturer".
    enum ActorKind {
        Human,
        Device
    }

    /// @notice The three activity streams identified in the Part A monitoring step.
    enum EmissionCategory {
        Scope1Combustion, // fuel combusted on site
        Scope1Process, // process emissions (e.g. calcination, reduction)
        Scope2Electricity // purchased electricity
    }

    /// @notice Lifecycle of a single emission record.
    /// Submitted and Queried are open states; Approved, Rejected and Superseded are terminal.
    enum RecordStatus {
        Submitted,
        Approved,
        Queried,
        Rejected,
        Superseded
    }

    /// @notice The three attestation outcomes available to a verifier under Part B.
    enum AttestationOutcome {
        Approve,
        Query,
        Reject
    }

    struct Facility {
        string name;
        string location;
        address manufacturer; // organisational identity; appoints its own operators
        bool active;
        uint64 registeredAt;
    }

    struct EmissionRecord {
        uint256 facilityId;
        EmissionCategory category;
        uint256 quantityKgCO2e; // integer kilograms; the EVM has no floating point
        uint64 periodStart; // inclusive, unix seconds
        uint64 periodEnd; // inclusive, unix seconds
        bytes32 evidenceHash; // digest of the off-chain evidence bundle
        address submitter; // individual or device key, never the org alone
        uint64 submittedAt;
        RecordStatus status;
        uint256 supersedes; // 0 if this is an original entry
        uint256 supersededBy; // 0 if this entry is still current
    }

    struct AttestationEntry {
        address verifier;
        AttestationOutcome outcome;
        uint64 attestedAt;
        bytes32 opinionHash; // digest of the off-chain ISO 14064-3 opinion
    }

    struct OperatorRecord {
        bool active;
        ActorKind kind;
        bytes32 credentialRef; // digest of the employment record or calibration certificate
    }

    // ---------------------------------------------------------------------
    // STORAGE
    // ---------------------------------------------------------------------

    /// @notice The consortium administrator (the regulator, per Part B).
    /// Immutable: the party that governs onboarding cannot be swapped out silently.
    address public immutable regulator;

    /// @notice Independent verifiers authorised to attest. Never also operators.
    mapping(address => bool) public isVerifier;

    /// @notice Facility and record identifiers both start at 1, so that 0 is a
    /// reliable "does not exist" sentinel for the supersedes/supersededBy pointers.
    uint256 public facilityCount;
    uint256 public recordCount;

    mapping(uint256 => Facility) private _facilities;
    mapping(uint256 => EmissionRecord) private _records;

    /// @notice Per-facility operator register. Authority is scoped to one facility:
    /// being an operator at plant A confers no rights at plant B.
    mapping(uint256 => mapping(address => OperatorRecord)) private _operators;

    /// @notice Index of record IDs per facility, for retrieval and aggregation.
    mapping(uint256 => uint256[]) private _facilityRecordIds;

    /// @notice Full attestation history per record. A queried record may be
    /// re-attested once the operator has answered the query off-chain, so this is
    /// an array rather than a single slot.
    mapping(uint256 => AttestationEntry[]) private _attestations;

    /// @notice Guards against the same evidence bundle being submitted twice.
    mapping(bytes32 => uint256) public recordIdByEvidenceHash;

    /// @dev Sanity ceiling: 1e12 kg is one billion tonnes CO2e for a single record,
    /// roughly twice South Africa's annual national inventory. Anything above this
    /// is a data-entry error, not a plausible reading.
    uint256 public constant MAX_QUANTITY_KG = 1e12;

    /// @dev A single record may not span more than 366 days.
    uint64 public constant MAX_PERIOD_SECONDS = 366 days;

    // ---------------------------------------------------------------------
    // EVENTS
    // ---------------------------------------------------------------------

    event FacilityRegistered(
        uint256 indexed facilityId, address indexed manufacturer, string name, string location, uint64 registeredAt
    );
    event FacilityDeactivated(uint256 indexed facilityId, uint64 deactivatedAt);
    event VerifierAuthorised(address indexed verifier);
    event VerifierRevoked(address indexed verifier);
    event OperatorAuthorised(
        uint256 indexed facilityId, address indexed operator, ActorKind kind, bytes32 credentialRef
    );
    event OperatorRevoked(uint256 indexed facilityId, address indexed operator);
    event EmissionRecordSubmitted(
        uint256 indexed recordId,
        uint256 indexed facilityId,
        address indexed submitter,
        EmissionCategory category,
        uint256 quantityKgCO2e,
        uint64 periodStart,
        uint64 periodEnd,
        bytes32 evidenceHash
    );
    event RecordAttested(
        uint256 indexed recordId, address indexed verifier, AttestationOutcome outcome, bytes32 opinionHash
    );
    event RecordSuperseded(uint256 indexed originalRecordId, uint256 indexed replacementRecordId);

    // ---------------------------------------------------------------------
    // ERRORS
    //
    // Custom errors rather than require strings: the selector is four bytes, so
    // both deployment and revert cost drop, and the failure carries structured
    // parameters a client can decode.
    // ---------------------------------------------------------------------

    error NotRegulator(address caller);
    error NotVerifier(address caller);
    error NotManufacturer(uint256 facilityId, address caller);
    error NotFacilityOperator(uint256 facilityId, address caller);
    error UnknownFacility(uint256 facilityId);
    error FacilityInactive(uint256 facilityId);
    error UnknownRecord(uint256 recordId);
    error EmptyField();
    error ZeroAddress();
    error ZeroHash();
    error InvalidQuantity(uint256 quantityKgCO2e);
    error InvalidPeriod(uint64 periodStart, uint64 periodEnd);
    error PeriodNotElapsed(uint64 periodEnd, uint256 blockTimestamp);
    error DuplicateEvidence(bytes32 evidenceHash, uint256 existingRecordId);
    error RecordNotOpen(uint256 recordId, RecordStatus status);
    error RecordNotSupersedable(uint256 recordId, RecordStatus status);
    error AlreadySuperseded(uint256 recordId, uint256 supersededBy);
    error FacilityMismatch(uint256 expectedFacilityId, uint256 actualFacilityId);
    error SeparationOfDuties(address account);
    error AlreadyHasRole(address account);
    error PaginationOutOfRange(uint256 offset, uint256 length);

    // ---------------------------------------------------------------------
    // MODIFIERS  (access control)
    // ---------------------------------------------------------------------

    modifier onlyRegulator() {
        if (msg.sender != regulator) revert NotRegulator(msg.sender);
        _;
    }

    modifier onlyVerifier() {
        if (!isVerifier[msg.sender]) revert NotVerifier(msg.sender);
        _;
    }

    /// @dev The manufacturer is the organisational account bound to a facility at
    /// registration. It appoints and revokes its own staff and devices — the
    /// regulator does not micro-manage a plant's personnel register, mirroring the
    /// way a Fabric organisation issues identities under its own MSP.
    modifier onlyManufacturer(uint256 facilityId) {
        _requireFacility(facilityId);
        if (_facilities[facilityId].manufacturer != msg.sender) revert NotManufacturer(facilityId, msg.sender);
        _;
    }

    /// @dev Two-layer check: the caller must hold an active operator record AND that
    /// record must belong to this specific facility.
    modifier onlyFacilityOperator(uint256 facilityId) {
        _requireActiveFacility(facilityId);
        if (!_operators[facilityId][msg.sender].active) revert NotFacilityOperator(facilityId, msg.sender);
        _;
    }

    // ---------------------------------------------------------------------
    // CONSTRUCTOR
    // ---------------------------------------------------------------------

    /// @param regulator_ The consortium administrator. Passed explicitly rather than
    /// defaulting to msg.sender so that deployment can be performed by a technical
    /// account without that account inheriting governance authority.
    constructor(address regulator_) {
        if (regulator_ == address(0)) revert ZeroAddress();
        regulator = regulator_;
    }

    // =====================================================================
    // MODULE 1 — CONTROL AND IDENTITY
    // Onboarding and revocation of facilities, verifiers, staff and devices.
    // =====================================================================

    /// @notice Register a manufacturing facility as a reporting entity.
    /// @dev Regulator-only: admission to the reporting population is a regulatory
    /// act, not something a manufacturer grants itself.
    function registerFacility(string calldata name, string calldata location, address manufacturer)
        external
        onlyRegulator
        returns (uint256 facilityId)
    {
        if (bytes(name).length == 0 || bytes(location).length == 0) revert EmptyField();
        if (manufacturer == address(0)) revert ZeroAddress();
        if (isVerifier[manufacturer] || manufacturer == regulator) revert SeparationOfDuties(manufacturer);

        facilityId = ++facilityCount;
        _facilities[facilityId] = Facility({
            name: name,
            location: location,
            manufacturer: manufacturer,
            active: true,
            registeredAt: uint64(block.timestamp)
        });

        emit FacilityRegistered(facilityId, manufacturer, name, location, uint64(block.timestamp));
    }

    /// @notice Deactivate a facility (decommissioning, or loss of authorisation).
    /// @dev Deactivation blocks new submissions only. Every historical record and
    /// attestation remains readable and unaltered — revocation must not retroactively
    /// invalidate signed history, per Part B.
    function deactivateFacility(uint256 facilityId) external onlyRegulator {
        _requireActiveFacility(facilityId);
        _facilities[facilityId].active = false;
        emit FacilityDeactivated(facilityId, uint64(block.timestamp));
    }

    /// @notice Authorise an independent verifier.
    function authoriseVerifier(address verifier) external onlyRegulator {
        if (verifier == address(0)) revert ZeroAddress();
        if (verifier == regulator) revert SeparationOfDuties(verifier);
        if (isVerifier[verifier]) revert AlreadyHasRole(verifier);
        isVerifier[verifier] = true;
        emit VerifierAuthorised(verifier);
    }

    /// @notice Revoke a verifier. Past attestations stand; only future ones are barred.
    function revokeVerifier(address verifier) external onlyRegulator {
        if (!isVerifier[verifier]) revert NotVerifier(verifier);
        isVerifier[verifier] = false;
        emit VerifierRevoked(verifier);
    }

    /// @notice Appoint a member of plant personnel, or provision a sensor key, for one facility.
    /// @param credentialRef Digest of the off-chain credential: an employment record
    /// for a human, a calibration certificate for a device. Storing the digest rather
    /// than the document keeps personal and commercial detail off the ledger.
    function authoriseOperator(uint256 facilityId, address operator, ActorKind kind, bytes32 credentialRef)
        external
        onlyManufacturer(facilityId)
    {
        if (operator == address(0)) revert ZeroAddress();
        if (credentialRef == bytes32(0)) revert ZeroHash();
        // A verifier must never be able to submit the figures it certifies, and the
        // regulator must never be able to author the data it supervises.
        if (isVerifier[operator] || operator == regulator) revert SeparationOfDuties(operator);
        if (_operators[facilityId][operator].active) revert AlreadyHasRole(operator);

        _operators[facilityId][operator] = OperatorRecord({active: true, kind: kind, credentialRef: credentialRef});
        emit OperatorAuthorised(facilityId, operator, kind, credentialRef);
    }

    /// @notice Revoke an operator — staff departure, or sensor decommissioning.
    function revokeOperator(uint256 facilityId, address operator) external onlyManufacturer(facilityId) {
        if (!_operators[facilityId][operator].active) revert NotFacilityOperator(facilityId, operator);
        _operators[facilityId][operator].active = false;
        emit OperatorRevoked(facilityId, operator);
    }

    // =====================================================================
    // MODULE 2 — EMISSION RECORDING
    // Append-only submission of validated readings and their evidence digests.
    // =====================================================================

    /// @notice Submit an emissions record for a facility.
    /// @param evidenceHash Digest of the off-chain evidence bundle (sensor log, lab
    /// report, calibration certificate). Computed off-chain, so the digest algorithm
    /// is a deployment choice: the contract stores and compares a fixed 32-byte
    /// fingerprint and is indifferent to whether it was produced by SHA-256 or keccak-256.
    /// @return recordId Identifier of the newly appended record.
    function submitEmissionRecord(
        uint256 facilityId,
        EmissionCategory category,
        uint256 quantityKgCO2e,
        uint64 periodStart,
        uint64 periodEnd,
        bytes32 evidenceHash
    ) external onlyFacilityOperator(facilityId) returns (uint256 recordId) {
        return _appendRecord(facilityId, category, quantityKgCO2e, periodStart, periodEnd, evidenceHash, 0);
    }

    /// @notice Submit a correcting record that supersedes an earlier one.
    /// @dev This is the only correction mechanism. The original record's content is
    /// untouched; it gains a forward pointer and a Superseded status, so an auditor
    /// reading the ledger sees both the figure originally reported and the figure
    /// that replaced it, along with who filed each and when.
    function submitCorrection(
        uint256 originalRecordId,
        EmissionCategory category,
        uint256 quantityKgCO2e,
        uint64 periodStart,
        uint64 periodEnd,
        bytes32 evidenceHash
    ) external returns (uint256 recordId) {
        _requireRecord(originalRecordId);
        EmissionRecord storage original = _records[originalRecordId];
        uint256 facilityId = original.facilityId;

        // Re-apply the operator check for the facility that owns the original record.
        _requireActiveFacility(facilityId);
        if (!_operators[facilityId][msg.sender].active) revert NotFacilityOperator(facilityId, msg.sender);

        if (original.supersededBy != 0) revert AlreadySuperseded(originalRecordId, original.supersededBy);
        // A record still under review must be dispositioned by a verifier before it
        // can be replaced, otherwise an operator could outrun scrutiny by resubmitting.
        if (original.status == RecordStatus.Submitted) {
            revert RecordNotSupersedable(originalRecordId, original.status);
        }

        recordId =
            _appendRecord(facilityId, category, quantityKgCO2e, periodStart, periodEnd, evidenceHash, originalRecordId);

        original.supersededBy = recordId;
        original.status = RecordStatus.Superseded;
        emit RecordSuperseded(originalRecordId, recordId);
    }

    /// @dev Shared validation and append path. Every input is checked before any
    /// state is written, so a malformed submission costs the caller a revert and
    /// leaves no partial entry behind.
    function _appendRecord(
        uint256 facilityId,
        EmissionCategory category,
        uint256 quantityKgCO2e,
        uint64 periodStart,
        uint64 periodEnd,
        bytes32 evidenceHash,
        uint256 supersedes
    ) private returns (uint256 recordId) {
        if (quantityKgCO2e == 0 || quantityKgCO2e > MAX_QUANTITY_KG) revert InvalidQuantity(quantityKgCO2e);
        if (periodEnd <= periodStart || periodEnd - periodStart > MAX_PERIOD_SECONDS) {
            revert InvalidPeriod(periodStart, periodEnd);
        }
        // A reporting period cannot be certified before it has finished.
        if (periodEnd > block.timestamp) revert PeriodNotElapsed(periodEnd, block.timestamp);
        if (evidenceHash == bytes32(0)) revert ZeroHash();

        uint256 existing = recordIdByEvidenceHash[evidenceHash];
        if (existing != 0) revert DuplicateEvidence(evidenceHash, existing);

        recordId = ++recordCount;
        _records[recordId] = EmissionRecord({
            facilityId: facilityId,
            category: category,
            quantityKgCO2e: quantityKgCO2e,
            periodStart: periodStart,
            periodEnd: periodEnd,
            evidenceHash: evidenceHash,
            submitter: msg.sender,
            submittedAt: uint64(block.timestamp),
            status: RecordStatus.Submitted,
            supersedes: supersedes,
            supersededBy: 0
        });

        recordIdByEvidenceHash[evidenceHash] = recordId;
        _facilityRecordIds[facilityId].push(recordId);

        emit EmissionRecordSubmitted(
            recordId, facilityId, msg.sender, category, quantityKgCO2e, periodStart, periodEnd, evidenceHash
        );
    }

    // =====================================================================
    // MODULE 3 — VERIFICATION AND ATTESTATION
    // A separately signed second step: what was submitted, and what was verified.
    // =====================================================================

    /// @notice Record a verifier's attestation against a submitted record.
    /// @param opinionHash Digest of the off-chain verification opinion.
    /// @dev Approve and Reject are terminal. Query leaves the record open so the
    /// verifier can attest again once the operator has answered off-chain; every
    /// attestation is appended, so the sequence of queries and the eventual
    /// disposition are both permanently visible.
    ///
    /// The operator cannot call this function and the verifier cannot call
    /// submitEmissionRecord, so no single key can both report and certify a figure.
    function attest(uint256 recordId, AttestationOutcome outcome, bytes32 opinionHash) external onlyVerifier {
        _requireRecord(recordId);
        if (opinionHash == bytes32(0)) revert ZeroHash();

        EmissionRecord storage record = _records[recordId];
        if (record.status != RecordStatus.Submitted && record.status != RecordStatus.Queried) {
            revert RecordNotOpen(recordId, record.status);
        }

        _attestations[recordId].push(
            AttestationEntry({
                verifier: msg.sender,
                outcome: outcome,
                attestedAt: uint64(block.timestamp),
                opinionHash: opinionHash
            })
        );

        if (outcome == AttestationOutcome.Approve) {
            record.status = RecordStatus.Approved;
        } else if (outcome == AttestationOutcome.Reject) {
            record.status = RecordStatus.Rejected;
        } else {
            record.status = RecordStatus.Queried;
        }

        emit RecordAttested(recordId, msg.sender, outcome, opinionHash);
    }

    // =====================================================================
    // MODULE 4 — REPORTING AND AUDIT TRAIL
    // Read-only retrieval for verifiers, the regulator and external auditors.
    // Read access is universal on a public EVM chain; the confidentiality control
    // is the on-chain/off-chain split, not a permission on these functions.
    // =====================================================================

    function getFacility(uint256 facilityId) external view returns (Facility memory) {
        _requireFacility(facilityId);
        return _facilities[facilityId];
    }

    function getRecord(uint256 recordId) external view returns (EmissionRecord memory) {
        _requireRecord(recordId);
        return _records[recordId];
    }

    function getAttestations(uint256 recordId) external view returns (AttestationEntry[] memory) {
        _requireRecord(recordId);
        return _attestations[recordId];
    }

    function getOperator(uint256 facilityId, address operator) external view returns (OperatorRecord memory) {
        _requireFacility(facilityId);
        return _operators[facilityId][operator];
    }

    function facilityRecordCount(uint256 facilityId) external view returns (uint256) {
        _requireFacility(facilityId);
        return _facilityRecordIds[facilityId].length;
    }

    /// @notice Paginated retrieval of a facility's record IDs.
    /// @dev Paginated deliberately. A facility reporting daily accumulates thousands
    /// of records, and a view function that returns an unbounded array will
    /// eventually exceed the node's gas cap for eth_call and fail — not on the day
    /// it is written, but on some later day in production.
    function getFacilityRecordIds(uint256 facilityId, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory page, uint256 nextOffset)
    {
        _requireFacility(facilityId);
        uint256[] storage ids = _facilityRecordIds[facilityId];
        uint256 length = ids.length;
        if (offset > length) revert PaginationOutOfRange(offset, length);

        uint256 end = offset + limit;
        if (end > length) end = length;
        page = new uint256[](end - offset);
        for (uint256 i = offset; i < end; ++i) {
            page[i - offset] = ids[i];
        }
        nextOffset = end;
    }

    /// @notice Total approved, non-superseded emissions for a facility over a window.
    /// @dev Also paginated, for the same reason. The caller aggregates across pages;
    /// the contract never runs an unbounded loop over storage.
    /// @return totalKgCO2e Sum over the scanned page only.
    /// @return matched Number of records in the page that met the criteria.
    /// @return nextOffset Offset to pass on the next call; equals the record count when done.
    function approvedTotal(uint256 facilityId, uint64 windowStart, uint64 windowEnd, uint256 offset, uint256 limit)
        external
        view
        returns (uint256 totalKgCO2e, uint256 matched, uint256 nextOffset)
    {
        _requireFacility(facilityId);
        if (windowEnd <= windowStart) revert InvalidPeriod(windowStart, windowEnd);

        uint256[] storage ids = _facilityRecordIds[facilityId];
        uint256 length = ids.length;
        if (offset > length) revert PaginationOutOfRange(offset, length);

        uint256 end = offset + limit;
        if (end > length) end = length;

        for (uint256 i = offset; i < end; ++i) {
            EmissionRecord storage record = _records[ids[i]];
            // Only approved, still-current records count toward a reported total.
            if (record.status != RecordStatus.Approved) continue;
            if (record.supersededBy != 0) continue;
            // The record's whole period must fall inside the requested window, so
            // that no reading is double counted across adjacent reporting periods.
            if (record.periodStart < windowStart || record.periodEnd > windowEnd) continue;

            totalKgCO2e += record.quantityKgCO2e;
            ++matched;
        }
        nextOffset = end;
    }

    /// @notice Check a candidate evidence digest against the one recorded on-chain.
    /// @dev The auditor's independent check: re-hash the document held off-chain and
    /// compare. A false result means the document in hand is not the document that
    /// was reported against.
    function verifyEvidence(uint256 recordId, bytes32 candidateHash) external view returns (bool) {
        _requireRecord(recordId);
        return _records[recordId].evidenceHash == candidateHash;
    }

    /// @notice Whether a record is the current version of its figure.
    function isCurrent(uint256 recordId) external view returns (bool) {
        _requireRecord(recordId);
        return _records[recordId].supersededBy == 0;
    }

    // ---------------------------------------------------------------------
    // INTERNAL GUARDS
    // ---------------------------------------------------------------------

    function _requireFacility(uint256 facilityId) private view {
        if (facilityId == 0 || facilityId > facilityCount) revert UnknownFacility(facilityId);
    }

    function _requireActiveFacility(uint256 facilityId) private view {
        _requireFacility(facilityId);
        if (!_facilities[facilityId].active) revert FacilityInactive(facilityId);
    }

    function _requireRecord(uint256 recordId) private view {
        if (recordId == 0 || recordId > recordCount) revert UnknownRecord(recordId);
    }
}
