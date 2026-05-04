UPDATE profiles
SET dupr_rating = ROUND(dupr_rating::NUMERIC, 3)
WHERE dupr_rating IS NOT NULL;

ALTER TABLE profiles
    ALTER COLUMN dupr_rating TYPE NUMERIC(5,3)
    USING ROUND(dupr_rating::NUMERIC, 3);

ALTER TABLE profiles
    ADD CONSTRAINT profiles_dupr_rating_precision_range_check
        CHECK (
            dupr_rating IS NULL
            OR (dupr_rating >= 2.000 AND dupr_rating <= 8.000)
        ) NOT VALID;
