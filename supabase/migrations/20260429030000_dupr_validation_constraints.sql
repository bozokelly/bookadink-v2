ALTER TABLE profiles
    ADD CONSTRAINT profiles_dupr_id_format_check
        CHECK (
            dupr_id IS NULL
            OR (
                dupr_id ~ '^[A-Z0-9-]+$'
                AND dupr_id ~ '[0-9]'
            )
        ) NOT VALID;
