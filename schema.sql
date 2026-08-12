-- Orakwe Relational Database Schema (PostgreSQL)
-- Designed for offline-first distributed synchronization (using UUIDs for primary keys)
-- and strict verification constraints to prevent overvoting and double-voting.

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- 1. Administrative Hierarchy Tables

CREATE TABLE countries (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name VARCHAR(100) NOT NULL UNIQUE,
    code VARCHAR(3) NOT NULL UNIQUE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE states (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    country_id UUID NOT NULL REFERENCES countries(id) ON DELETE RESTRICT,
    name VARCHAR(100) NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(country_id, name)
);

CREATE TABLE lgas (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    state_id UUID NOT NULL REFERENCES states(id) ON DELETE RESTRICT,
    name VARCHAR(100) NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(state_id, name)
);

CREATE TABLE wards (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    lga_id UUID NOT NULL REFERENCES lgas(id) ON DELETE RESTRICT,
    name VARCHAR(100) NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(lga_id, name)
);

CREATE TABLE polling_units (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    ward_id UUID NOT NULL REFERENCES wards(id) ON DELETE RESTRICT,
    name VARCHAR(150) NOT NULL,
    code VARCHAR(20) NOT NULL UNIQUE, -- E.g. "36-01-01-001" (State-LGA-Ward-PU format)
    latitude DECIMAL(9, 6) CHECK (latitude BETWEEN -90 AND 90),
    longitude DECIMAL(9, 6) CHECK (longitude BETWEEN -180 AND 180),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- 2. Electoral Boundaries & Constituencies

CREATE TYPE constituency_type AS ENUM (
    'PRESIDENTIAL', 
    'SENATORIAL', 
    'FEDERAL_CONSTITUENCY', 
    'STATE_CONSTITUENCY', 
    'LGA_CHAIRMAN', 
    'COUNCILLOR'
);

CREATE TABLE constituencies (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    type constituency_type NOT NULL,
    name VARCHAR(150) NOT NULL,
    state_id UUID REFERENCES states(id) ON DELETE RESTRICT, -- Null for presidential, required for state/senatorial/etc
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(type, name, state_id)
);

-- Maps administrative subdivisions to electoral constituencies.
-- A constituency consists of a set of LGAs, Wards, or individual Polling Units.
CREATE TABLE constituency_boundaries (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    constituency_id UUID NOT NULL REFERENCES constituencies(id) ON DELETE CASCADE,
    lga_id UUID REFERENCES lgas(id) ON DELETE RESTRICT,
    ward_id UUID REFERENCES wards(id) ON DELETE RESTRICT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    -- Ensure a boundary entry maps to either a Ward or an LGA, not both, to keep the hierarchy clean
    CONSTRAINT chk_boundary_level CHECK (
        (lga_id IS NOT NULL AND ward_id IS NULL) OR 
        (lga_id IS NULL AND ward_id IS NOT NULL) OR
        (lga_id IS NULL AND ward_id IS NULL) -- For Presidential where it applies nationwide
    )
);

-- 3. Party & Voter Registries

CREATE TABLE political_parties (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name VARCHAR(150) NOT NULL UNIQUE,
    code VARCHAR(10) NOT NULL UNIQUE, -- E.g. "APC", "LP", "PDP"
    logo_url VARCHAR(255),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE TYPE voter_status AS ENUM ('ACTIVE', 'TRANSFERRED', 'INACTIVE', 'SUSPENDED');

CREATE TABLE voters (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    vin VARCHAR(19) NOT NULL UNIQUE, -- Voter Identification Number (e.g. 90F5B12345678901234)
    first_name VARCHAR(100) NOT NULL,
    last_name VARCHAR(100) NOT NULL,
    gender VARCHAR(1) CHECK (gender IN ('M', 'F')),
    date_of_birth DATE NOT NULL,
    fingerprint_hash VARCHAR(64) NOT NULL UNIQUE, -- SHA-256 representation of biometric fingerprint template
    facial_hash VARCHAR(64) NOT NULL UNIQUE,       -- SHA-256 representation of biometric facial template
    polling_unit_id UUID NOT NULL REFERENCES polling_units(id) ON DELETE RESTRICT,
    status voter_status NOT NULL DEFAULT 'ACTIVE',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE TYPE transfer_status AS ENUM ('PENDING', 'APPROVED', 'REJECTED');

CREATE TABLE voter_transfers (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    voter_id UUID NOT NULL REFERENCES voters(id) ON DELETE RESTRICT,
    source_polling_unit_id UUID NOT NULL REFERENCES polling_units(id) ON DELETE RESTRICT,
    destination_polling_unit_id UUID NOT NULL REFERENCES polling_units(id) ON DELETE RESTRICT,
    status transfer_status NOT NULL DEFAULT 'PENDING',
    requested_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    processed_at TIMESTAMP WITH TIME ZONE,
    processed_by VARCHAR(100), -- Admin ID or official reference
    CONSTRAINT chk_different_pus CHECK (source_polling_unit_id <> destination_polling_unit_id)
);

-- 4. Elections & Candidates

CREATE TYPE election_status AS ENUM ('DRAFT', 'ACTIVE', 'SUSPENDED', 'CONCLUDED');

CREATE TABLE elections (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name VARCHAR(150) NOT NULL,
    date DATE NOT NULL,
    status election_status NOT NULL DEFAULT 'DRAFT',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE candidates (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    election_id UUID NOT NULL REFERENCES elections(id) ON DELETE RESTRICT,
    constituency_id UUID NOT NULL REFERENCES constituencies(id) ON DELETE RESTRICT,
    political_party_id UUID NOT NULL REFERENCES political_parties(id) ON DELETE RESTRICT,
    first_name VARCHAR(100) NOT NULL,
    last_name VARCHAR(100) NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    -- A party can only field one candidate per constituency in any given election
    UNIQUE(election_id, constituency_id, political_party_id)
);

-- 5. Vote Accreditation & Results (Integrity Engine)

-- Log of individual voter accreditation on Election Day.
-- Enforces the "Vote Once" rule at the database level.
CREATE TABLE voter_accreditations (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    voter_id UUID NOT NULL REFERENCES voters(id) ON DELETE RESTRICT,
    election_id UUID NOT NULL REFERENCES elections(id) ON DELETE RESTRICT,
    polling_unit_id UUID NOT NULL REFERENCES polling_units(id) ON DELETE RESTRICT,
    accredited_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    -- Prevent double accreditation for the same voter in the same election
    UNIQUE(voter_id, election_id)
);

-- Aggregated accreditation counts from the BVAS device at the Polling Unit.
CREATE TABLE polling_unit_accreditation_totals (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    election_id UUID NOT NULL REFERENCES elections(id) ON DELETE RESTRICT,
    polling_unit_id UUID NOT NULL REFERENCES polling_units(id) ON DELETE RESTRICT,
    total_registered INT NOT NULL CHECK (total_registered >= 0),
    total_accredited INT NOT NULL CHECK (total_accredited >= 0),
    bvas_sync_time TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(election_id, polling_unit_id),
    CONSTRAINT chk_accredited_limit CHECK (total_accredited <= total_registered)
);

CREATE TYPE result_status AS ENUM ('SUBMITTED', 'VERIFIED', 'DISPUTED', 'VOID_OVERVOTING');

-- Form EC8A data: Raw results at the Polling Unit level.
CREATE TABLE polling_unit_results (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    election_id UUID NOT NULL REFERENCES elections(id) ON DELETE RESTRICT,
    polling_unit_id UUID NOT NULL REFERENCES polling_units(id) ON DELETE RESTRICT,
    candidate_id UUID NOT NULL REFERENCES candidates(id) ON DELETE RESTRICT,
    votes_count INT NOT NULL CHECK (votes_count >= 0),
    form_ec8a_url VARCHAR(255), -- Link to image/PDF of physical Form EC8A
    status result_status NOT NULL DEFAULT 'SUBMITTED',
    submitted_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    verified_at TIMESTAMP WITH TIME ZONE,
    UNIQUE(election_id, polling_unit_id, candidate_id)
);

-- Collation tables at Ward (EC8B), LGA (EC8C), State (EC8D), and National levels.
CREATE TYPE collation_level AS ENUM ('WARD', 'LGA', 'CONSTITUENCY', 'STATE', 'NATIONAL');

CREATE TABLE collation_results (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    election_id UUID NOT NULL REFERENCES elections(id) ON DELETE RESTRICT,
    level collation_level NOT NULL,
    level_id UUID NOT NULL, -- References ward_id, lga_id, constituency_id, etc.
    candidate_id UUID NOT NULL REFERENCES candidates(id) ON DELETE RESTRICT,
    total_votes INT NOT NULL CHECK (total_votes >= 0),
    form_url VARCHAR(255), -- Link to the signed physical collation sheet (EC8B/C/D)
    compiled_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    compiled_by VARCHAR(100) NOT NULL, -- Collation Officer name/ID
    UNIQUE(election_id, level, level_id, candidate_id)
);

-- 6. Indexes for Performance Optimization

-- Geographic traversal and aggregations
CREATE INDEX idx_polling_units_ward ON polling_units(ward_id);
CREATE INDEX idx_wards_lga ON wards(lga_id);
CREATE INDEX idx_lgas_state ON lgas(state_id);

-- Constituency lookups
CREATE INDEX idx_constituency_boundaries_constituency ON constituency_boundaries(constituency_id);
CREATE INDEX idx_constituencies_state ON constituencies(state_id);

-- Candidate and election queries
CREATE INDEX idx_candidates_election_constituency ON candidates(election_id, constituency_id);

-- Voter registry searches
CREATE INDEX idx_voters_polling_unit ON voters(polling_unit_id);
CREATE INDEX idx_voters_status ON voters(status);

-- Accreditation checks
CREATE INDEX idx_voter_accreditations_voter_election ON voter_accreditations(voter_id, election_id);
CREATE INDEX idx_polling_unit_accreditation_totals_lookup ON polling_unit_accreditation_totals(election_id, polling_unit_id);

-- Result tabulation and rollup aggregation speed
CREATE INDEX idx_polling_unit_results_lookup ON polling_unit_results(election_id, polling_unit_id);
CREATE INDEX idx_collation_results_lookup ON collation_results(election_id, level, level_id);
