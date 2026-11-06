const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("IPConfig", function () {
  let ipconfig, usdt;
  let admin, creator, licensee, other;
  const PLATFORM_FEE_BPS = 300; // 3%
  const REG_FEE = ethers.parseEther("0.01");

  beforeEach(async () => {
    [admin, creator, licensee, other] = await ethers.getSigners();

    // Deploy mock USDT (6 decimals)
    const ERC20Mock = await ethers.getContractFactory("ERC20Mock");
    usdt = await ERC20Mock.deploy("Mock USDT", "USDT", 6);
    await usdt.mint(licensee.address, ethers.parseUnits("10000", 6));

    const IPConfig = await ethers.getContractFactory("IPConfig");
    ipconfig = await IPConfig.deploy(
      await usdt.getAddress(),
      PLATFORM_FEE_BPS,
      REG_FEE
    );
  });

  // ─── Registration ─────────────────────────────────────────────────────────

  describe("IP Registration", () => {
    it("registers IP with correct fields", async () => {
      const hash = ethers.keccak256(ethers.toUtf8Bytes("my_novel.pdf"));
      await ipconfig.connect(creator).registerIP(
        "My Novel", 0, "A great story", 1700000000, hash, "ipfs://meta", creator.address,
        { value: REG_FEE }
      );
      const ip = await ipconfig.getIPRecord(1);
      expect(ip.title).to.equal("My Novel");
      expect(ip.rightsHolder).to.equal(creator.address);
      expect(ip.workHash).to.equal(hash);
      expect(ip.isActive).to.be.true;
    });

    it("rejects duplicate hash", async () => {
      const hash = ethers.keccak256(ethers.toUtf8Bytes("file.pdf"));
      await ipconfig.connect(creator).registerIP(
        "Title 1", 0, "Desc", 1700000000, hash, "", creator.address, { value: REG_FEE }
      );
      await expect(
        ipconfig.connect(other).registerIP(
          "Title 2", 0, "Desc", 1700000000, hash, "", other.address, { value: REG_FEE }
        )
      ).to.be.revertedWith("Hash already registered");
    });

    it("rejects insufficient registration fee", async () => {
      const hash = ethers.keccak256(ethers.toUtf8Bytes("file2.pdf"));
      await expect(
        ipconfig.connect(creator).registerIP(
          "Title", 0, "Desc", 1700000000, hash, "", creator.address,
          { value: ethers.parseEther("0.001") }
        )
      ).to.be.revertedWith("Insufficient registration fee");
    });

    it("rejects zero hash", async () => {
      await expect(
        ipconfig.connect(creator).registerIP(
          "Title", 0, "Desc", 1700000000, ethers.ZeroHash, "", creator.address,
          { value: REG_FEE }
        )
      ).to.be.revertedWith("Hash required");
    });
  });

  // ─── License Terms ────────────────────────────────────────────────────────

  describe("License Terms", () => {
    let ipId;
    beforeEach(async () => {
      const hash = ethers.keccak256(ethers.toUtf8Bytes("work.mp3"));
      const tx = await ipconfig.connect(creator).registerIP(
        "My Song", 1, "A track", 1700000000, hash, "", creator.address, { value: REG_FEE }
      );
      ipId = 1;
    });

    it("publishes terms and increments version", async () => {
      await ipconfig.connect(creator).publishLicenseTerms(
        ipId, "Personal use only", "No commercial use",
        false, false, true,
        ethers.parseEther("1"), ethers.parseUnits("5", 6), 365
      );
      const terms = await ipconfig.getActiveTerms(ipId);
      expect(terms.version).to.equal(1);
      expect(terms.commercialAllowed).to.be.false;
      expect(terms.durationDays).to.equal(365);

      // Publish v2 — v1 must remain unchanged
      await ipconfig.connect(creator).publishLicenseTerms(
        ipId, "Commercial allowed", "Attribution required",
        true, true, true,
        ethers.parseEther("5"), ethers.parseUnits("20", 6), 0
      );
      const v2 = await ipconfig.getActiveTerms(ipId);
      expect(v2.version).to.equal(2);

      const history = await ipconfig.getTermsHistory(ipId);
      expect(history.length).to.equal(2);
      expect(history[0].commercialAllowed).to.be.false; // v1 unchanged
    });

    it("rejects terms from non-holder", async () => {
      await expect(
        ipconfig.connect(other).publishLicenseTerms(
          ipId, "Uses", "Restrictions", true, true, false,
          ethers.parseEther("1"), 0, 30
        )
      ).to.be.revertedWith("Not rights holder");
    });
  });

  // ─── License Purchase ─────────────────────────────────────────────────────

  describe("License Purchase", () => {
    let ipId;
    const feeBOT = ethers.parseEther("2");
    const feeUSDT = ethers.parseUnits("10", 6);

    beforeEach(async () => {
      const hash = ethers.keccak256(ethers.toUtf8Bytes("software.zip"));
      await ipconfig.connect(creator).registerIP(
        "SDK", 3, "Dev SDK", 1700000000, hash, "", creator.address, { value: REG_FEE }
      );
      ipId = 1;
      await ipconfig.connect(creator).publishLicenseTerms(
        ipId, "Build with it", "No resale", true, false, false,
        feeBOT, feeUSDT, 90
      );
    });

    it("purchases with BOT and credits revenue", async () => {
      await ipconfig.connect(licensee).purchaseLicenseWithBOT(ipId, "For my app", { value: feeBOT });
      const licId = 1;
      const lic = await ipconfig.getLicense(licId);
      expect(lic.licensee).to.equal(licensee.address);
      expect(lic.status).to.equal(0); // Active

      const payout = feeBOT - (feeBOT * BigInt(PLATFORM_FEE_BPS)) / 10000n;
      expect(await ipconfig.pendingRevenueBOT(creator.address)).to.equal(payout);
    });

    it("purchases with USDT and credits revenue", async () => {
      const addr = await ipconfig.getAddress();
      await usdt.connect(licensee).approve(addr, feeUSDT);
      await ipconfig.connect(licensee).purchaseLicenseWithUSDT(ipId, "For project");
      const payout = feeUSDT - (feeUSDT * BigInt(PLATFORM_FEE_BPS)) / 10000n;
      expect(await ipconfig.pendingRevenueUSDT(creator.address)).to.equal(payout);
    });

    it("isLicenseActive returns true within window", async () => {
      await ipconfig.connect(licensee).purchaseLicenseWithBOT(ipId, "", { value: feeBOT });
      expect(await ipconfig.isLicenseActive(1)).to.be.true;
    });

    it("isLicenseActive returns false after expiry", async () => {
      await ipconfig.connect(licensee).purchaseLicenseWithBOT(ipId, "", { value: feeBOT });
      await time.increase(91 * 24 * 3600);
      expect(await ipconfig.isLicenseActive(1)).to.be.false;
    });
  });

  // ─── Revocation ───────────────────────────────────────────────────────────

  describe("Revocation", () => {
    it("rights holder can revoke a license", async () => {
      const hash = ethers.keccak256(ethers.toUtf8Bytes("art.png"));
      await ipconfig.connect(creator).registerIP(
        "Artwork", 2, "Digital art", 1700000000, hash, "", creator.address, { value: REG_FEE }
      );
      await ipconfig.connect(creator).publishLicenseTerms(
        1, "Display only", "No prints", false, false, true,
        ethers.parseEther("1"), 0, 0
      );
      await ipconfig.connect(licensee).purchaseLicenseWithBOT(1, "", { value: ethers.parseEther("1") });
      await ipconfig.connect(creator).revokeLicense(1);
      const lic = await ipconfig.getLicense(1);
      expect(lic.status).to.equal(2); // Revoked
    });

    it("non-holder cannot revoke", async () => {
      const hash = ethers.keccak256(ethers.toUtf8Bytes("art2.png"));
      await ipconfig.connect(creator).registerIP(
        "Artwork2", 2, "Art", 1700000000, hash, "", creator.address, { value: REG_FEE }
      );
      await ipconfig.connect(creator).publishLicenseTerms(
        1, "Display only", "No prints", false, false, true,
        ethers.parseEther("1"), 0, 0
      );
      await ipconfig.connect(licensee).purchaseLicenseWithBOT(1, "", { value: ethers.parseEther("1") });
      await expect(ipconfig.connect(other).revokeLicense(1)).to.be.revertedWith("Not authorized");
    });
  });

  // ─── Ownership Transfer ───────────────────────────────────────────────────

  describe("Ownership Transfer", () => {
    it("two-step transfer works correctly", async () => {
      const hash = ethers.keccak256(ethers.toUtf8Bytes("transfer.pdf"));
      await ipconfig.connect(creator).registerIP(
        "IP to Transfer", 0, "Desc", 1700000000, hash, "", creator.address, { value: REG_FEE }
      );
      await ipconfig.connect(creator).proposeOwnershipTransfer(1, other.address);
      await ipconfig.connect(other).acceptOwnershipTransfer(1);
      const ip = await ipconfig.getIPRecord(1);
      expect(ip.rightsHolder).to.equal(other.address);
    });

    it("non-proposed address cannot accept", async () => {
      const hash = ethers.keccak256(ethers.toUtf8Bytes("transfer2.pdf"));
      await ipconfig.connect(creator).registerIP(
        "IP 2", 0, "Desc", 1700000000, hash, "", creator.address, { value: REG_FEE }
      );
      await ipconfig.connect(creator).proposeOwnershipTransfer(1, other.address);
      await expect(
        ipconfig.connect(licensee).acceptOwnershipTransfer(1)
      ).to.be.revertedWith("Not proposed owner");
    });
  });

  // ─── Revenue Withdrawal ───────────────────────────────────────────────────

  describe("Revenue Withdrawal", () => {
    it("creator can withdraw BOT revenue", async () => {
      const hash = ethers.keccak256(ethers.toUtf8Bytes("wd.pdf"));
      await ipconfig.connect(creator).registerIP(
        "WD IP", 0, "", 1700000000, hash, "", creator.address, { value: REG_FEE }
      );
      const feeBOT = ethers.parseEther("3");
      await ipconfig.connect(creator).publishLicenseTerms(1, "", "", true, true, false, feeBOT, 0, 0);
      await ipconfig.connect(licensee).purchaseLicenseWithBOT(1, "", { value: feeBOT });

      const before = await ethers.provider.getBalance(creator.address);
      const tx = await ipconfig.connect(creator).withdrawRevenueBOT();
      const receipt = await tx.wait();
      const gas = receipt.gasUsed * receipt.gasPrice;
      const after = await ethers.provider.getBalance(creator.address);

      const expected = feeBOT - (feeBOT * BigInt(PLATFORM_FEE_BPS)) / 10000n;
      expect(after - before + gas).to.be.closeTo(expected, ethers.parseEther("0.001"));
    });
  });

  // ─── Admin ────────────────────────────────────────────────────────────────

  describe("Admin", () => {
    it("can flag and unflag IP", async () => {
      const hash = ethers.keccak256(ethers.toUtf8Bytes("flag.pdf"));
      await ipconfig.connect(creator).registerIP(
        "Flaggable", 0, "", 1700000000, hash, "", creator.address, { value: REG_FEE }
      );
      await ipconfig.connect(admin).flagIP(1, true);
      expect((await ipconfig.getIPRecord(1)).isFlagged).to.be.true;
      await ipconfig.connect(admin).flagIP(1, false);
      expect((await ipconfig.getIPRecord(1)).isFlagged).to.be.false;
    });

    it("non-admin cannot flag", async () => {
      const hash = ethers.keccak256(ethers.toUtf8Bytes("flag2.pdf"));
      await ipconfig.connect(creator).registerIP(
        "Flaggable2", 0, "", 1700000000, hash, "", creator.address, { value: REG_FEE }
      );
      await expect(ipconfig.connect(other).flagIP(1, true)).to.be.revertedWith("Not admin");
    });

    it("resolves dispute and flags IP", async () => {
      const hash = ethers.keccak256(ethers.toUtf8Bytes("dispute.pdf"));
      await ipconfig.connect(creator).registerIP(
        "Disputed", 0, "", 1700000000, hash, "", creator.address, { value: REG_FEE }
      );
      await ipconfig.connect(other).reportDispute(1, "Plagiarism claim");
      await ipconfig.connect(admin).resolveDispute(1, 1, "Confirmed infringement"); // Resolved
      const ip = await ipconfig.getIPRecord(1);
      expect(ip.isFlagged).to.be.true;
    });
  });

  // ─── Disputes ─────────────────────────────────────────────────────────────

  describe("Disputes", () => {
    it("anyone can report a dispute", async () => {
      const hash = ethers.keccak256(ethers.toUtf8Bytes("disp.pdf"));
      await ipconfig.connect(creator).registerIP(
        "Disputeable", 0, "", 1700000000, hash, "", creator.address, { value: REG_FEE }
      );
      await ipconfig.connect(licensee).reportDispute(1, "I created this first");
      const d = await ipconfig.getDispute(1);
      expect(d.reporter).to.equal(licensee.address);
      expect(d.status).to.equal(0); // Open
    });
  });
});
