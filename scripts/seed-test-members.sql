-- Seed 6 test members into a club.
-- Run in Supabase SQL Editor (postgres role) or via psql with a service-role connection.
-- Idempotent: re-running matches existing rows by synthetic email and updates instead of duplicating.
--
-- For each player this creates:
--   1. auth.users row with empty encrypted_password (cannot log in)
--   2. profiles row (full_name, email, dupr_rating rounded to 3dp)
--   3. club_members row with status='approved'

DO $$
DECLARE
    v_club_id UUID := 'f82430f3-1048-4cca-ad91-6f189a84ae55';
    v_player RECORD;
    v_user_id UUID;
    v_email TEXT;
    v_slug TEXT;
    v_now TIMESTAMPTZ := now();
    v_existing_member_id UUID;
BEGIN
    -- Sanity: club must exist
    IF NOT EXISTS (SELECT 1 FROM public.clubs WHERE id = v_club_id) THEN
        RAISE EXCEPTION 'Club % not found', v_club_id;
    END IF;

    FOR v_player IN
        SELECT *
        FROM (VALUES
            ('Roszie Nelson',  2.022::numeric),
            ('Richard Smith',  2.662::numeric),
            ('David Strahle',  2.670::numeric),
            ('Thanh Strahle',  2.513::numeric),
            ('Mark Ollett',    2.507::numeric),
            ('Julie Lowe',     3.3332::numeric)  -- will round to 3.333 by NUMERIC(5,3)
        ) AS t(full_name, dupr_rating)
    LOOP
        -- Build a deterministic synthetic email so re-runs are idempotent
        v_slug := regexp_replace(lower(v_player.full_name), '[^a-z0-9]+', '-', 'g');
        v_slug := trim(both '-' from v_slug);
        v_email := 'bookadink+test-' || v_slug || '@example.invalid';

        -- Find or create the auth user
        SELECT id INTO v_user_id
        FROM auth.users
        WHERE email = v_email
        LIMIT 1;

        IF v_user_id IS NULL THEN
            v_user_id := gen_random_uuid();
            INSERT INTO auth.users (
                id,
                instance_id,
                aud,
                role,
                email,
                encrypted_password,         -- empty: no valid password, login impossible
                email_confirmed_at,
                raw_app_meta_data,
                raw_user_meta_data,
                created_at,
                updated_at,
                is_sso_user,
                is_anonymous
            ) VALUES (
                v_user_id,
                '00000000-0000-0000-0000-000000000000',
                'authenticated',
                'authenticated',
                v_email,
                '',
                v_now,
                '{"provider":"email","providers":["email"]}'::jsonb,
                jsonb_build_object(
                    'full_name', v_player.full_name,
                    'seed_source', 'seed-test-members.sql'
                ),
                v_now,
                v_now,
                false,
                false
            );
            RAISE NOTICE 'auth.users created: % (%)', v_player.full_name, v_user_id;
        ELSE
            RAISE NOTICE 'auth.users exists:  % (%)', v_player.full_name, v_user_id;
        END IF;

        -- Upsert profile.
        -- If a handle_new_user trigger already created a stub row, ON CONFLICT updates it.
        INSERT INTO public.profiles (id, full_name, email, dupr_rating)
        VALUES (
            v_user_id,
            v_player.full_name,
            v_email,
            round(v_player.dupr_rating, 3)  -- explicit round for Julie's 3.3332 → 3.333
        )
        ON CONFLICT (id) DO UPDATE
        SET full_name   = EXCLUDED.full_name,
            email       = EXCLUDED.email,
            dupr_rating = EXCLUDED.dupr_rating;

        -- Ensure approved club membership (no assumption about UNIQUE constraint on club_members)
        SELECT id INTO v_existing_member_id
        FROM public.club_members
        WHERE club_id = v_club_id AND user_id = v_user_id
        LIMIT 1;

        IF v_existing_member_id IS NULL THEN
            INSERT INTO public.club_members (
                club_id,
                user_id,
                status,
                requested_at,
                conduct_accepted_at,
                cancellation_policy_accepted_at
            ) VALUES (
                v_club_id,
                v_user_id,
                'approved',
                v_now,
                v_now,
                v_now
            );
            RAISE NOTICE 'club_members added:  %', v_player.full_name;
        ELSE
            UPDATE public.club_members
            SET status = 'approved'
            WHERE id = v_existing_member_id AND status <> 'approved';
            RAISE NOTICE 'club_members exists: %', v_player.full_name;
        END IF;
    END LOOP;
END $$;

-- Verification: show what's now in the club for these test users
SELECT
    p.full_name,
    p.email,
    p.dupr_rating,
    cm.status,
    cm.requested_at
FROM public.club_members cm
JOIN public.profiles p ON p.id = cm.user_id
WHERE cm.club_id = 'f82430f3-1048-4cca-ad91-6f189a84ae55'
  AND p.email LIKE 'bookadink+test-%@example.invalid'
ORDER BY p.full_name;
