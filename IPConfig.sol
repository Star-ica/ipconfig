// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IPConfig — Onchain Intellectual Property Registry
 * @notice Records IP claims, licensing terms, and license purchases on BOT Chain.
 *
 * IMPORTANT LEGAL DISCLAIMER:
 * Onchain registration provides a timestamped evidence record of a claim —
 * it does NOT constitute legal proof of authorship, originality, or copyright
 * ownership under any jurisdiction. A cryptographic hash demonstrates that a
 * specific file existed at registration time, not that the registrant created it.
 * Legal recognition of intellectual property rights requires compliance with
 * applicable laws and, where disputes arise, adjudication by competent legal authority.
 */

interface IERC20 {
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract IPConfig {

    // ─── State ────────────────────────────────────────────────────────────────

    address public admin;
    address public usdtToken;
    uint256 public platformFeeBps;       // e.g. 300 = 3%
    uint256 public registrationFeeWei;   // flat fee in BOT to register IP

    uint256 private _nextIpId   = 1;
    uint256 private _nextTermsId = 1;
    uint256 private _nextLicenseId = 1;
    uint256 private _nextDisputeId = 1;

    // ─── Enums ────────────────────────────────────────────────────────────────

    enum IPCategory { Literary, Musical, Artistic, Software, Film, Patent, Trademark, Other }
    enum LicenseStatus { Active, Expired, Revoked }
    enum DisputeStatus { Open, Resolved, Dismissed }
    enum PayToken { BOT, USDT }

    // ─── Structs ──────────────────────────────────────────────────────────────

    struct IPRecord {
        uint256 id;
        address rightsHolder;
        string  title;
        IPCategory category;
        string  description;
        uint256 creationDate;       // Unix timestamp declared by registrant
        uint256 registrationDate;   // block.timestamp at registration
        bytes32 workHash;           // keccak256 or SHA-256 of original file
        string  metadataUri;        // optional external reference (not stored file)
        bool    isActive;
        bool    isFlagged;          // admin-flagged for review
        uint256 activeTermsId;      // current license terms version
    }

    // Versioned license terms — once published, a version is immutable.
    // Licensees always get the terms version that was active when they purchased.
    struct LicenseTerms {
        uint256 id;
        uint256 ipId;
        uint256 version;
        string  permittedUses;      // human-readable description
        string  restrictions;
        bool    commercialAllowed;
        bool    derivativesAllowed;
        bool    attributionRequired;
        uint256 feeBOT;             // per-license fee in BOT (18 dec)
        uint256 feeUSDT;            // per-license fee in USDT (6 dec)
        uint256 durationDays;       // 0 = perpetual
        uint256 publishedAt;
    }

    struct License {
        uint256 id;
        uint256 ipId;
        uint256 termsId;            // snapshot of which terms version
        address licensee;
        PayToken payToken;
        uint256 amountPaid;
        uint256 issuedAt;
        uint256 expiresAt;          // 0 = perpetual
        LicenseStatus status;
        string  licenseeNote;
    }

    struct Dispute {
        uint256 id;
        uint256 ipId;
        address reporter;
        string  reason;
        uint256 reportedAt;
        DisputeStatus status;
        string  resolution;
    }

    struct OwnershipTransferRequest {
        uint256 ipId;
        address proposedOwner;
        uint256 proposedAt;
        bool    accepted;
    }

    // ─── Storage ──────────────────────────────────────────────────────────────

    mapping(uint256 => IPRecord)                    public ipRecords;
    mapping(uint256 => LicenseTerms[])              public ipTermsHistory;   // ipId → all versions
    mapping(uint256 => LicenseTerms)                public termsById;
    mapping(uint256 => License)                     public licenses;
    mapping(uint256 => Dispute)                     public disputes;
    mapping(uint256 => OwnershipTransferRequest)    public transferRequests; // ipId → pending request
    mapping(address => uint256[])                   public holderIPs;
    mapping(address => uint256[])                   public licenseeLicenses;
    mapping(uint256 => uint256[])                   public ipLicenses;
    mapping(address => uint256)                     public pendingRevenueBOT;
    mapping(address => uint256)                     public pendingRevenueUSDT;

    // For duplicate-hash detection
    mapping(bytes32 => uint256) public hashToIpId;

    // ─── Events ───────────────────────────────────────────────────────────────

    event IPRegistered(uint256 indexed ipId, address indexed rightsHolder, bytes32 workHash, string title);
    event TermsPublished(uint256 indexed ipId, uint256 indexed termsId, uint256 version);
    event LicensePurchased(uint256 indexed licenseId, uint256 indexed ipId, address indexed licensee);
    event LicenseRevoked(uint256 indexed licenseId, address revokedBy);
    event DisputeReported(uint256 indexed disputeId, uint256 indexed ipId, address reporter);
    event DisputeResolved(uint256 indexed disputeId, DisputeStatus outcome);
    event OwnershipTransferProposed(uint256 indexed ipId, address indexed proposed);
    event OwnershipTransferred(uint256 indexed ipId, address indexed from, address indexed to);
    event RevenueWithdrawn(address indexed holder, PayToken token, uint256 amount);
    event IPFlagged(uint256 indexed ipId, bool flagged);
    event RegistrationFeeUpdated(uint256 newFee);
    event PlatformFeeUpdated(uint256 newBps);

    // ─── Modifiers ────────────────────────────────────────────────────────────

    modifier onlyAdmin() {
        require(msg.sender == admin, "Not admin");
        _;
    }

    modifier onlyIPHolder(uint256 ipId) {
        require(ipRecords[ipId].rightsHolder == msg.sender, "Not rights holder");
        _;
    }

    modifier ipExists(uint256 ipId) {
        require(ipRecords[ipId].id != 0, "IP not found");
        _;
    }

    // ─── Constructor ──────────────────────────────────────────────────────────

    constructor(address _usdtToken, uint256 _platformFeeBps, uint256 _registrationFeeWei) {
        admin               = msg.sender;
        usdtToken           = _usdtToken;
        platformFeeBps      = _platformFeeBps;
        registrationFeeWei  = _registrationFeeWei;
    }

    // ─── Admin ────────────────────────────────────────────────────────────────

    function setRegistrationFee(uint256 _fee) external onlyAdmin {
        registrationFeeWei = _fee;
        emit RegistrationFeeUpdated(_fee);
    }

    function setPlatformFee(uint256 _bps) external onlyAdmin {
        require(_bps <= 1000, "Max 10%");
        platformFeeBps = _bps;
        emit PlatformFeeUpdated(_bps);
    }

    function setUSDTToken(address _usdt) external onlyAdmin {
        usdtToken = _usdt;
    }

    function flagIP(uint256 ipId, bool flagged) external onlyAdmin ipExists(ipId) {
        ipRecords[ipId].isFlagged = flagged;
        emit IPFlagged(ipId, flagged);
    }

    function resolveDispute(uint256 disputeId, DisputeStatus outcome, string calldata resolution)
        external onlyAdmin
    {
        Dispute storage d = disputes[disputeId];
        require(d.id != 0, "Dispute not found");
        require(d.status == DisputeStatus.Open, "Already resolved");
        d.status     = outcome;
        d.resolution = resolution;
        if (outcome == DisputeStatus.Resolved) {
            ipRecords[d.ipId].isFlagged = true;
        }
        emit DisputeResolved(disputeId, outcome);
    }

    function withdrawAdminFees(address token, uint256 amount) external onlyAdmin {
        if (token == address(0)) {
            (bool ok, ) = payable(admin).call{value: amount}("");
            require(ok, "Transfer failed");
        } else {
            require(IERC20(token).transfer(admin, amount), "Transfer failed");
        }
    }

    function transferAdmin(address newAdmin) external onlyAdmin {
        require(newAdmin != address(0), "Zero address");
        admin = newAdmin;
    }

    // ─── IP Registration ──────────────────────────────────────────────────────

    /**
     * @notice Register an IP claim.
     * @dev The workHash should be computed off-chain (keccak256 or SHA-256 of file).
     *      Duplicate hashes are rejected to prevent trivial re-registration.
     */
    function registerIP(
        string  calldata title,
        IPCategory category,
        string  calldata description,
        uint256 creationDate,
        bytes32 workHash,
        string  calldata metadataUri,
        address rightsHolder
    ) external payable returns (uint256 ipId) {
        require(msg.value >= registrationFeeWei, "Insufficient registration fee");
        require(bytes(title).length > 0, "Title required");
        require(workHash != bytes32(0), "Hash required");
        require(hashToIpId[workHash] == 0, "Hash already registered");
        require(rightsHolder != address(0), "Invalid rights holder");

        ipId = _nextIpId++;
        ipRecords[ipId] = IPRecord({
            id:               ipId,
            rightsHolder:     rightsHolder,
            title:            title,
            category:         category,
            description:      description,
            creationDate:     creationDate,
            registrationDate: block.timestamp,
            workHash:         workHash,
            metadataUri:      metadataUri,
            isActive:         true,
            isFlagged:        false,
            activeTermsId:    0
        });

        hashToIpId[workHash] = ipId;
        holderIPs[rightsHolder].push(ipId);

        emit IPRegistered(ipId, rightsHolder, workHash, title);
    }

    // ─── License Terms ────────────────────────────────────────────────────────

    /**
     * @notice Publish a new version of license terms for an IP.
     *         Previously issued licenses retain the terms version they were purchased under.
     */
    function publishLicenseTerms(
        uint256 ipId,
        string  calldata permittedUses,
        string  calldata restrictions,
        bool    commercialAllowed,
        bool    derivativesAllowed,
        bool    attributionRequired,
        uint256 feeBOT,
        uint256 feeUSDT,
        uint256 durationDays
    ) external onlyIPHolder(ipId) ipExists(ipId) returns (uint256 termsId) {
        require(feeBOT > 0 || feeUSDT > 0, "At least one fee required");

        uint256 version = ipTermsHistory[ipId].length + 1;
        termsId = _nextTermsId++;

        LicenseTerms memory t = LicenseTerms({
            id:                   termsId,
            ipId:                 ipId,
            version:              version,
            permittedUses:        permittedUses,
            restrictions:         restrictions,
            commercialAllowed:    commercialAllowed,
            derivativesAllowed:   derivativesAllowed,
            attributionRequired:  attributionRequired,
            feeBOT:               feeBOT,
            feeUSDT:              feeUSDT,
            durationDays:         durationDays,
            publishedAt:          block.timestamp
        });

        ipTermsHistory[ipId].push(t);
        termsById[termsId] = t;
        ipRecords[ipId].activeTermsId = termsId;

        emit TermsPublished(ipId, termsId, version);
    }

    // ─── License Purchase ─────────────────────────────────────────────────────

    function purchaseLicenseWithBOT(
        uint256 ipId,
        string  calldata licenseeNote
    ) external payable ipExists(ipId) returns (uint256 licenseId) {
        IPRecord storage ip = ipRecords[ipId];
        require(ip.isActive && !ip.isFlagged, "IP not available");
        require(ip.activeTermsId != 0, "No terms set");

        LicenseTerms storage t = termsById[ip.activeTermsId];
        require(t.feeBOT > 0, "BOT not accepted");
        require(msg.value >= t.feeBOT, "Insufficient BOT");

        licenseId = _issueLicense(ipId, ip.activeTermsId, PayToken.BOT, t.feeBOT, t.durationDays, licenseeNote);

        uint256 fee     = (t.feeBOT * platformFeeBps) / 10000;
        uint256 payout  = t.feeBOT - fee;
        pendingRevenueBOT[ip.rightsHolder] += payout;

        if (msg.value > t.feeBOT) {
            (bool ok, ) = payable(msg.sender).call{value: msg.value - t.feeBOT}("");
            require(ok, "Refund failed");
        }
    }

    function purchaseLicenseWithUSDT(
        uint256 ipId,
        string  calldata licenseeNote
    ) external ipExists(ipId) returns (uint256 licenseId) {
        IPRecord storage ip = ipRecords[ipId];
        require(ip.isActive && !ip.isFlagged, "IP not available");
        require(ip.activeTermsId != 0, "No terms set");

        LicenseTerms storage t = termsById[ip.activeTermsId];
        require(t.feeUSDT > 0, "USDT not accepted");

        require(IERC20(usdtToken).transferFrom(msg.sender, address(this), t.feeUSDT), "USDT transfer failed");

        licenseId = _issueLicense(ipId, ip.activeTermsId, PayToken.USDT, t.feeUSDT, t.durationDays, licenseeNote);

        uint256 fee    = (t.feeUSDT * platformFeeBps) / 10000;
        uint256 payout = t.feeUSDT - fee;
        pendingRevenueUSDT[ip.rightsHolder] += payout;
    }

    function _issueLicense(
        uint256 ipId,
        uint256 termsId,
        PayToken token,
        uint256 amount,
        uint256 durationDays,
        string  calldata note
    ) internal returns (uint256 licenseId) {
        licenseId = _nextLicenseId++;
        uint256 expiresAt = durationDays == 0
            ? 0
            : block.timestamp + (durationDays * 1 days);

        licenses[licenseId] = License({
            id:           licenseId,
            ipId:         ipId,
            termsId:      termsId,
            licensee:     msg.sender,
            payToken:     token,
            amountPaid:   amount,
            issuedAt:     block.timestamp,
            expiresAt:    expiresAt,
            status:       LicenseStatus.Active,
            licenseeNote: note
        });

        licenseeLicenses[msg.sender].push(licenseId);
        ipLicenses[ipId].push(licenseId);

        emit LicensePurchased(licenseId, ipId, msg.sender);
    }

    // ─── Revocation ───────────────────────────────────────────────────────────

    function revokeLicense(uint256 licenseId) external {
        License storage l = licenses[licenseId];
        require(l.id != 0, "License not found");
        require(l.status == LicenseStatus.Active, "Not active");

        uint256 ipId = l.ipId;
        require(
            ipRecords[ipId].rightsHolder == msg.sender || msg.sender == admin,
            "Not authorized"
        );

        l.status = LicenseStatus.Revoked;
        emit LicenseRevoked(licenseId, msg.sender);
    }

    // ─── Revenue Withdrawal ───────────────────────────────────────────────────

    function withdrawRevenueBOT() external {
        uint256 amount = pendingRevenueBOT[msg.sender];
        require(amount > 0, "Nothing to withdraw");
        pendingRevenueBOT[msg.sender] = 0;
        (bool ok, ) = payable(msg.sender).call{value: amount}("");
        require(ok, "Transfer failed");
        emit RevenueWithdrawn(msg.sender, PayToken.BOT, amount);
    }

    function withdrawRevenueUSDT() external {
        uint256 amount = pendingRevenueUSDT[msg.sender];
        require(amount > 0, "Nothing to withdraw");
        pendingRevenueUSDT[msg.sender] = 0;
        require(IERC20(usdtToken).transfer(msg.sender, amount), "Transfer failed");
        emit RevenueWithdrawn(msg.sender, PayToken.USDT, amount);
    }

    // ─── Ownership Transfer ───────────────────────────────────────────────────

    function proposeOwnershipTransfer(uint256 ipId, address proposed)
        external onlyIPHolder(ipId) ipExists(ipId)
    {
        require(proposed != address(0) && proposed != msg.sender, "Invalid proposed owner");
        transferRequests[ipId] = OwnershipTransferRequest({
            ipId:          ipId,
            proposedOwner: proposed,
            proposedAt:    block.timestamp,
            accepted:      false
        });
        emit OwnershipTransferProposed(ipId, proposed);
    }

    function acceptOwnershipTransfer(uint256 ipId) external ipExists(ipId) {
        OwnershipTransferRequest storage req = transferRequests[ipId];
        require(req.proposedOwner == msg.sender, "Not proposed owner");
        require(!req.accepted, "Already accepted");

        address from = ipRecords[ipId].rightsHolder;
        req.accepted = true;
        ipRecords[ipId].rightsHolder = msg.sender;
        holderIPs[msg.sender].push(ipId);
        // Note: does not remove from previous holder's array (keep historical record)

        emit OwnershipTransferred(ipId, from, msg.sender);
    }

    // ─── Disputes ─────────────────────────────────────────────────────────────

    function reportDispute(uint256 ipId, string calldata reason) external ipExists(ipId) {
        require(bytes(reason).length > 0, "Reason required");
        uint256 disputeId = _nextDisputeId++;
        disputes[disputeId] = Dispute({
            id:         disputeId,
            ipId:       ipId,
            reporter:   msg.sender,
            reason:     reason,
            reportedAt: block.timestamp,
            status:     DisputeStatus.Open,
            resolution: ""
        });
        emit DisputeReported(disputeId, ipId, msg.sender);
    }

    // ─── View Functions ───────────────────────────────────────────────────────

    function getIPRecord(uint256 ipId) external view returns (IPRecord memory) {
        return ipRecords[ipId];
    }

    function getActiveTerms(uint256 ipId) external view returns (LicenseTerms memory) {
        return termsById[ipRecords[ipId].activeTermsId];
    }

    function getTermsHistory(uint256 ipId) external view returns (LicenseTerms[] memory) {
        return ipTermsHistory[ipId];
    }

    function getLicense(uint256 licenseId) external view returns (License memory) {
        return licenses[licenseId];
    }

    function isLicenseActive(uint256 licenseId) external view returns (bool) {
        License storage l = licenses[licenseId];
        if (l.status != LicenseStatus.Active) return false;
        if (l.expiresAt == 0) return true;
        return block.timestamp < l.expiresAt;
    }

    function getHolderIPs(address holder) external view returns (uint256[] memory) {
        return holderIPs[holder];
    }

    function getLicenseeLicenses(address licensee) external view returns (uint256[] memory) {
        return licenseeLicenses[licensee];
    }

    function getIPLicenses(uint256 ipId) external view returns (uint256[] memory) {
        return ipLicenses[ipId];
    }

    function getDispute(uint256 disputeId) external view returns (Dispute memory) {
        return disputes[disputeId];
    }

    function getTotalIPs() external view returns (uint256) { return _nextIpId - 1; }
    function getTotalLicenses() external view returns (uint256) { return _nextLicenseId - 1; }

    receive() external payable {}
}
