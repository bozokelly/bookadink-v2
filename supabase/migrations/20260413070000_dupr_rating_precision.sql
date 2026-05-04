-- Fix: dupr_rating stored as NUMERIC(x,2) silently rounds 3-decimal values.
-- Change to DOUBLE PRECISION so 2.992 stores and returns as 2.992.
ALTER TABLE profiles
  ALTER COLUMN dupr_rating TYPE DOUBLE PRECISION;
