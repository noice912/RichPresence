# Code signing with Azure Artifact Signing

Signed builds show your verified name instead of "Unknown publisher" and get past browser and SmartScreen warnings faster.
Azure Artifact Signing (formerly *Trusted Signing*) costs about **$10/month** (Basic: 5,000 signatures).

The release workflow (`.github/workflows/build.yml`) already contains the signing steps. They stay **switched off** until
you create the `SIGNING_ACCOUNT` variable in step 8, so unsigned builds keep working in the meantime.

> Requirements (as of 2026): a **paid** Azure subscription (free/trial/sponsored ones don't work), and for an individual,
> a location in the **United States or Canada**. The legal name on your Azure billing account must match your government ID.
> Docs: <https://learn.microsoft.com/azure/artifact-signing/quickstart>

## 1. Azure account + paid subscription
Sign in at <https://portal.azure.com> and upgrade to **Pay-as-you-go**.

## 2. Make the billing account an "Individual" with your real legal name
Azure portal -> **Cost Management + Billing** -> your billing account. The account type must be **Individual**, and the
**legal name and sold-to address must match your government ID exactly**. That name appears on the certificate.

## 3. Register the resource provider
Portal -> **Subscriptions** -> your subscription -> **Resource providers** -> `Microsoft.CodeSigning` -> **...** -> **Register**.

## 4. Create the signing account
Portal -> search **Artifact Signing Accounts** -> **Create**:
- Resource group: create new (e.g. `richpresence-signing`)
- Account name: unique, 3-24 letters/numbers (e.g. `richpresencesign`)
- Region: pick one close to you, and **note its endpoint URL** (East US = `https://eus.codesigning.azure.net`)
- Pricing: **Basic**

## 5. Give yourself the Identity Verifier role
On the account -> **Access control (IAM)** -> **Add role assignment** -> **Artifact Signing Identity Verifier** -> assign to yourself.
(Without it, the "New identity" button is greyed out.)

## 6. Identity validation (the slow step - a few minutes to days)
Account -> **Identity validations** -> **Individual** -> **New identity** -> **Public**. Pick your billing account, check the
details, **Create**. When the status becomes **Action Required**, open the verification link, sign in with the **same email**
you entered, and follow the steps: you'll scan QR codes with your phone and photograph a government ID + selfie
(via AU10TIX and Microsoft Authenticator). Status changes to **Completed** afterwards.

## 7. Create the certificate profile
Account -> **Certificate profiles** -> **Create** -> **Public Trust**:
- Name: e.g. `richpresence-profile`
- Verified CN and O: select your completed identity validation

## 8. Let GitHub sign in to Azure (no password stored)
1. Portal -> **Microsoft Entra ID** -> **App registrations** -> **New registration** -> name `richpresence-github` -> Register.
   Copy the **Application (client) ID** and **Directory (tenant) ID**.
2. On that app -> **Certificates & secrets** -> **Federated credentials** -> **Add credential**:
   - Scenario: **GitHub Actions deploying Azure resources**
   - Organization: `noice912`, Repository: `RichPresence`
   - Entity type: **Environment**, Environment name: `release`
   - Name: `github-release` -> Add
3. On your **Artifact Signing account** -> **Access control (IAM)** -> **Add role assignment** ->
   **Artifact Signing Certificate Profile Signer** -> Members: select `richpresence-github`.
4. Copy your **Subscription ID** (Portal -> Subscriptions).

## 9. Add the settings to GitHub
Repo -> **Settings** -> **Environments** -> **New environment** -> name it exactly `release`. In that environment add:

**Environment secrets**

| Name | Value |
|---|---|
| `AZURE_CLIENT_ID` | Application (client) ID from step 8 |
| `AZURE_TENANT_ID` | Directory (tenant) ID |
| `AZURE_SUBSCRIPTION_ID` | Your subscription ID |

**Environment variables**

| Name | Value |
|---|---|
| `SIGNING_ENDPOINT` | The endpoint for your region, e.g. `https://eus.codesigning.azure.net` |
| `SIGNING_ACCOUNT` | Your signing account name (step 4) |
| `SIGNING_PROFILE` | Your certificate profile name (step 7) |

## 10. Release a signed build
```bash
git tag v1.0.1
git push origin v1.0.1
```
Open the run on the **Actions** tab. The *Show signature* step prints `Signature status: Valid` and your name.
Then download the EXE, right-click -> **Properties** -> **Digital Signatures** to see your verified name.

## Notes
- SmartScreen reputation still builds up over time as people download the signed file, but the "unknown publisher" warning is gone.
- Artifact Signing certificates are short-lived on purpose; the workflow adds a timestamp so the signature stays valid after the certificate expires.
- Don't create secrets as repository-wide values. Keep them in the `release` environment so only release builds can use them.
- Stop the billing by deleting the Artifact Signing account (Portal -> Artifact Signing Accounts -> Delete).
