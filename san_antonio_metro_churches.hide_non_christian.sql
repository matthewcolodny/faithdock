-- Hides the 20 confirmed non-Christian orgs found in the San Antonio batch
-- (5 you named + 15 more found by the same keyword sweep). Scoped to this
-- batch's filename; if any row here returns 0 affected, it's one of the
-- 19 rows that predate this batch (see the earlier find_missing.sql) and
-- needs a separate UPDATE without the filename restriction -- check
-- which afterward.
UPDATE churches
SET is_hidden = true
WHERE import_source_filename = 'san_antonio_metro_churches.clean.csv'
  AND name IN (
    'Moussa Temple No 106 Ancient Egyptian Arabic Order',   -- fraternal order (Shriners-adjacent), not a church of any faith
    'Life Synagogue Temple of Truth Inc',                    -- Jewish (denom tag: Jewish)
    'Dao Tam Buddhist Temple',                               -- Buddhist
    'Sri Shirdi Sai Baba Temple of San Antonio',             -- Hindu
    'San Antonio Temple of Cao Dai Tay Ninh Inc',            -- Cao Dai (Vietnamese)
    'Buddhist Temple of San Antonio Inc',                    -- Buddhist
    'Congregation Beth-El',                                  -- Jewish
    'Congregation Agudas Achim',                             -- Jewish (you named this one)
    'Congregation Rodfei Sholom Bnai Israel',                -- Jewish (you named this one)
    'New Jewish Congregation',                                -- Jewish
    'Hindu Temple of San Antonio',                            -- Hindu
    'Dhammabucha Buddist Temple of San Antonio',              -- Buddhist (same address as Sangha-Bucha below)
    'Sangha-Bucha Buddhist Temple',                           -- Buddhist (you named this one)
    'Wat Saddhadhamma Buddist 1518 Temple',                   -- Buddhist
    'Mother Temple',                                          -- Hindu (address: c/o an M.D. named Rama K Rao) (you named this one)
    'Temple Chai',                                            -- Jewish (common Reform congregation name)
    'Congregation Shalom of San Antonio',                     -- Jewish (you named this one)
    'Gam Yachad Congregation',                                -- Jewish (Hebrew name)
    'Re-Formed Congregation of the Goddess Inc',              -- Neopagan/Goddess-worship
    'Beth Simcha Messianic Synagogue'                         -- Jewish denom tag + "Synagogue" in name -- flagging: Messianic congregations sometimes self-identify as Christian; included here on the literal name+denom signal, your call if you want it kept
  );
