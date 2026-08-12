# Orakwe

An open-source elections and vote collation infrastructure designed to handle complex, hierarchical electoral systems. Orakwe is modeled after the Nigerian electoral framework, mapping real-world administrative boundaries directly to database structures to ensure accurate aggregation, verification, and auditability.

---

## 1. Administrative Hierarchy

In Nigeria, political geography is organized into five strict containment levels. Voting always occurs at the lowest level (Polling Unit), and results are aggregated upward through the administrative hierarchy:

```
[Country] ──> [State] ──> [Local Government Area (LGA)] ──> [Registration Area (Ward)] ──> [Polling Unit]
```

| Administrative Level | Total Count | Description |
| :--- | :--- | :--- |
| **Country** | 1 | Nigeria |
| **State / FCT** | 37 | 36 States + 1 Federal Capital Territory (Abuja) |
| **LGA / Area Council** | 774 | 774 Local Government Areas / FCT Area Councils |
| **Registration Area (RA) / Ward** | 8,813 | Electoral Wards within each LGA |
| **Polling Unit (PU)** | 176,974 | The fundamental unit where voting takes place on Election Day |

---

## 2. Electoral Constituencies & Positions

Not all elections are bounded by simple administrative lines. In Nigeria, contested positions map to distinct **Electoral Constituencies**, which represent a grouping of Polling Units:

### Federal Elections
*   **Presidential:** A single nationwide constituency. Includes all 176,974 Polling Units.
*   **Senatorial:** 109 Senatorial Districts. Each of the 36 states is divided into 3 Senatorial Districts, plus 1 for the FCT.
*   **House of Representatives:** 360 Federal Constituencies. Each constituency comprises one or more LGAs (or parts of LGAs) and elects one Representative.

### State Elections
*   **Gubernatorial (Governorship):** 36 state-wide constituencies (FCT has no Governor; it is administered federally).
*   **State House of Assembly:** 993 State Constituencies. Each state is divided into assembly constituencies (typically subdivisions of LGAs) to elect members of the State House of Assembly.

### Local Government Elections
*   **LGA Chairman:** 774 LGA-wide constituencies.
*   **Councillor:** 8,813 ward-wide constituencies.

---

## 3. Data Modeling & Relationships

In `orakwe`, the database schema is built around two primary concepts: **Administrative Entities** and **Electoral Constituencies**.

### Entity Schema Design

1.  **Administrative Boundaries (Strict Tree Structure):**
    *   `State` belongs to `Country`
    *   `LGA` belongs to `State`
    *   `Ward` belongs to `LGA`
    *   `PollingUnit` belongs to `Ward`

2.  **Constituencies (Many-to-Many Mapping):**
    *   A `Constituency` is defined by a specific type (e.g., `Senatorial`, `FederalConstituency`, `StateConstituency`) and is linked to one or more `LGA`s or `Ward`s.
    *   The `PollingUnit` resolves its active constituencies dynamically by traversing upward through `Ward` and `LGA`.

---

## 4. Vote Collation Flow & Forms

Orakwe models the physical collation process of the Independent National Electoral Commission (INEC). Votes are documented using standardized forms at each level:

```
[Polling Unit] ───────────> [Ward Collation] ───────────> [LGA Collation] ───────────> [Constituency/State]
  Form EC8A                   Form EC8B                    Form EC8C                    Form EC8D
  (Accredited vs Cast)        (Aggregated Wards)           (Aggregated LGAs)            (Declaration)
```

1.  **Polling Unit (Form EC8A):**
    *   Accredited voters (verified via Bimodal Voter Accreditation System - BVAS) are recorded.
    *   Physical ballots are counted; valid/invalid votes per political party are recorded.
    *   Results are uploaded to the infrastructure.
2.  **Ward / Registration Area (Form EC8B):**
    *   Aggregates Form EC8A results from all polling units within the ward.
3.  **Local Government Area (Form EC8C):**
    *   Aggregates Form EC8B results from all wards within the LGA.
4.  **Constituency / State Collation (Form EC8D & EC8E):**
    *   Aggregates LGA-level counts for final declaration of Senatorial, House of Representatives, Governorship, or Presidential winners.

---

## 5. Voter Registration & Voting Rules

To prevent electoral fraud and ensure true democratic representation, the Orakwe system enforces strict business rules governing voter registration, location constraints, ballot eligibility, and vote limits.

### 5.1 Voter Registration & PVC
*   **Biometric Identity:** Every voter must be registered in the national database with unique biometric credentials (fingerprints and facial mapping) to prevent duplicate registrations.
*   **Permanent Voter Card (PVC):** Registered voters are issued a PVC, storing their unique Voter Identification Number (VIN) and the specific Polling Unit (PU) to which they are assigned.
*   **Dynamic Transfer:** A voter can only change their assigned PU through an official voter transfer process. Upon approval, the voter record is deactivated in the source PU and activated in the destination PU.

### 5.2 Voting Rules & Boundaries

Where a voter can vote and who they can vote for is strictly governed by their registered Polling Unit. On Election Day, a voter is only presented with ballots relevant to the constituencies containing their Polling Unit:

| Election Type | Ballot Sheet | Location Constraint | Ballot Options (Who they can vote for) |
| :--- | :--- | :--- | :--- |
| **Presidential** | 1 Presidential Ballot | Must be voter's registered PU | Nationwide presidential candidates representing political parties |
| **Senatorial** | 1 Senatorial Ballot | Must be voter's registered PU | Candidates contesting in the Senatorial District containing the voter's PU |
| **House of Reps** | 1 Reps Ballot | Must be voter's registered PU | Candidates contesting in the Federal Constituency containing the voter's PU |
| **Gubernatorial** | 1 Governorship Ballot | Must be voter's registered PU | Candidates contesting in the State containing the voter's PU |
| **State Assembly** | 1 Assembly Ballot | Must be voter's registered PU | Candidates contesting in the State Constituency containing the voter's PU |
| **LGA Chairman** | 1 LGA Chairman Ballot | Must be voter's registered PU | Candidates contesting in the LGA containing the voter's PU |
| **Councillor** | 1 Councillor Ballot | Must be voter's registered PU | Candidates contesting in the Ward containing the voter's PU |

### 5.3 Accreditation & Vote Verification (Single Voting Rules)

*   **Biometric Accreditation:** Before receiving any ballot sheet, a voter must present their PVC and be authenticated biometrics-wise (face/fingerprint) by the Bimodal Voter Accreditation System (BVAS) at their registered Polling Unit.
*   **Single Voting Enforcement:** 
    *   **Accreditation Record:** The BVAS marks the voter as "Accredited" for the specific election day, blocking subsequent accreditation attempts.
    *   **Physical Verification:** Indelible ink is applied to the voter's finger/cuticle upon receiving the ballots.
*   **Overvoting Prevention (Mathematical Integrity Constraint):** The total number of cast votes ($V_{\text{cast}}$) at a Polling Unit must never exceed the total number of accredited voters ($A_{\text{bvas}}$) recorded by the BVAS for that unit:
    $$V_{\text{cast}} \le A_{\text{bvas}}$$
    If $V_{\text{cast}} > A_{\text{bvas}}$, the election at that specific Polling Unit is declared void due to overvoting (under Section 51 of the Electoral Act 2022).
