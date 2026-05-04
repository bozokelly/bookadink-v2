-- Clear legacy venue_name (Display Location) data from clubs.
-- This field was a free-text landmark label separate from the structured
-- venue system (club_venues table). Apple MapKit / club_venues is now the
-- sole source of truth for location display. Nulling this prevents the old
-- value from surfacing as a fallback anywhere in the codebase.

UPDATE clubs SET venue_name = NULL WHERE venue_name IS NOT NULL;
