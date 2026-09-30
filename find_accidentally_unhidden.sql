-- READ ONLY. Run in the Supabase SQL Editor.
--
-- WHY THE FIRST ATTEMPT FOUND NOTHING
--
-- admin_set_church_hidden (migration 102, line 181) is:
--
--   update churches set is_hidden = hidden, hidden_by_batch = false
--    where id = target_church_id;
--
-- It clears hidden_by_batch on its way past. So un-hiding a church by
-- hand erases the very flag that would have identified it. Nothing was
-- missed -- the fingerprint was destroyed by the act itself, and no row
-- history exists to ask instead.
--
-- So: re-derive it. Every deliberate hide in this repo is either a list
-- of ids or a list of names, and the one that got away is a row that
-- should be hidden and is not.

-- 1 -------------------------------------------------------------------
-- CERTAIN. Every id this repo ever hid on purpose. Anything listed here
-- that comes back is the church, named outright.
--   migration 018            -- test/internal churches
--   hide_zero_signal_ministries.sql
with deliberately_hidden(id, why) as (
  values
    ('4b2cb761-3d49-4d47-ac7f-81c98308daee'::uuid, '018 test/internal'),
    ('eecf143e-ee26-4383-bcd4-3cd49f38687d'::uuid, '018 test/internal'),
    ('3ebef06e-eb4a-4674-a232-6c80abfa5683'::uuid, '018 test/internal'),
    ('acd1af32-0dde-499f-8f26-f9e9a121324c'::uuid, '018 test/internal'),
    ('ce5fc05e-4b02-4489-acfb-da672c5391f4'::uuid, '018 test/internal'),
    ('70326648-7eb8-44fd-90a4-717953812d71'::uuid, 'zero-signal ministry'),
    ('d6903d47-00f3-48a6-9d35-e0c7ef3704f5'::uuid, 'zero-signal ministry'),
    ('2701aea7-f047-40a2-aadd-acdd043fb7cf'::uuid, 'zero-signal ministry'),
    ('7eff8683-c738-46af-b041-48f02fff30d8'::uuid, 'zero-signal ministry'),
    ('ce39b895-86b4-4c50-bfc2-d2795f9eb77e'::uuid, 'zero-signal ministry'),
    ('bb920b89-6774-4382-8dad-8e592b2176b1'::uuid, 'zero-signal ministry')
)
select c.id, c.name, c.address, d.why, '*** VISIBLE, SHOULD BE HIDDEN ***' as verdict
  from deliberately_hidden d
  join churches c on c.id = d.id
 where c.is_hidden = false;

-- 2 -------------------------------------------------------------------
-- ALSO CERTAIN. The 20 non-Christian organisations hidden by name in
-- hide_non_christian.sql. Any of these showing means it is the one.
select id, name, address, 'non-Christian org' as why,
       '*** VISIBLE, SHOULD BE HIDDEN ***' as verdict
  from churches
 where is_hidden = false
   and name in (
     'Moussa Temple No 106 Ancient Egyptian Arabic Order',
     'Life Synagogue Temple of Truth Inc',
     'Dao Tam Buddhist Temple',
     'Sri Shirdi Sai Baba Temple of San Antonio',
     'San Antonio Temple of Cao Dai Tay Ninh Inc',
     'Buddhist Temple of San Antonio Inc',
     'Congregation Beth-El',
     'Congregation Agudas Achim',
     'Congregation Rodfei Sholom Bnai Israel',
     'New Jewish Congregation',
     'Hindu Temple of San Antonio',
     'Dhammabucha Buddist Temple of San Antonio',
     'Sangha-Bucha Buddhist Temple',
     'Wat Saddhadhamma Buddist 1518 Temple',
     'Mother Temple',
     'Temple Chai',
     'Congregation Shalom of San Antonio',
     'Gam Yachad Congregation',
     'Re-Formed Congregation of the Goddess Inc',
     'Beth Simcha Messianic Synagogue'
   );

-- 3 -------------------------------------------------------------------
-- LIKELY, if 1 and 2 are both empty. The two lists above cover 31 of
-- the ~487 hidden churches, so the one that got away may belong to
-- whatever hid the rest. This is the same signal those sweeps used --
-- a non-Christian or zero-signal name in the first import -- restricted
-- to rows that are currently visible. Short enough to read; the odd one
-- out should be obvious.
select id, name, address,
       (phone is null or phone = '')     as no_phone,
       (website is null or website = '') as no_website
  from churches
 where is_hidden = false
   and import_batch_id = '2026-09-11T23:03:36.521Z_san_antonio_metro_churches.clean.csv'
   and (
        name ~* '(temple|synagogue|congregation|buddh|hindu|islam|masjid|mosque|sikh|gurdwara|cao dai|baha)'
     or (name ~* 'ministr' and coalesce(phone,'') = '' and coalesce(website,'') = '')
   )
 order by name;

-- 4 -------------------------------------------------------------------
-- Context, so the numbers make sense whatever the above returns.
select
  count(*) filter (where is_hidden)                          as hidden_now,
  count(*) filter (where is_hidden and hidden_by_batch)      as hidden_by_a_batch_action,
  count(*) filter (where is_hidden and not hidden_by_batch)  as hidden_some_other_way,
  count(*) filter (where not is_hidden)                      as visible_now
from churches;
