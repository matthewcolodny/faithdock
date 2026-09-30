-- Run in Supabase SQL Editor. TEST DATA — reversible, see the bottom.
--
-- Eight groups on the church owned by robbybudnick@gmail.com, so the
-- Groups browse filter has something to filter. Tagged across all four
-- vocabularies and spread over the three meeting formats.
--
-- ---------------------------------------------------------------------
-- WHY THESE COLUMNS
--
-- Exactly the set index.html writes when a leader saves a group, read
-- off the payload rather than guessed: name, description, church_id,
-- created_by, visibility, join_method, the meeting_* fields,
-- leader_can_view_contact_info, show_member_list, and the two added by
-- migration 115. Anything else on the table keeps its default.
--
-- Every row is marked with '[seed]' at the end of the description,
-- which is what the cleanup at the bottom matches on. Nothing else is
-- touched.

do $$
declare
  v_user_id   uuid;
  v_church_id uuid;
  v_inserted  integer;
begin
  select id into v_user_id from auth.users where lower(email) = 'robbybudnick@gmail.com';
  if v_user_id is null then
    raise exception 'ABORT: no account found for robbybudnick@gmail.com.';
  end if;

  -- The church they own. If they own more than one, the oldest wins --
  -- say so rather than picking silently.
  select id into v_church_id
    from churches where owner_id = v_user_id
   order by created_at asc limit 1;

  if v_church_id is null then
    raise exception 'ABORT: that account does not own a church, and a group has to belong to one.';
  end if;

  if (select count(*) from churches where owner_id = v_user_id) > 1 then
    raise notice 'That account owns more than one church; seeding into the oldest (%).', v_church_id;
  end if;

  insert into groups (
    name, description, church_id, created_by,
    visibility, join_method,
    meeting_recurrence, meeting_day_of_week, meeting_time, meeting_schedule,
    meeting_format, group_tags,
    leader_can_view_contact_info, show_member_list
  )
  values
    ('Tuesday Morning Women''s Bible Study',
     'A slow walk through Luke, coffee on. Childcare in the next room. [seed]',
     v_church_id, v_user_id, 'public', 'open',
     'weekly', 'Tuesday', '09:30', 'Weekly on Tuesday at 9:30 AM',
     'in_person', array['gwho:women','gdo:bible-study','gacc:childcare','gacc:newcomers','lang:english'],
     true, true),

    ('Men''s Prayer Breakfast',
     'First Saturday of the month. Eggs, then prayer. [seed]',
     v_church_id, v_user_id, 'public', 'open',
     'monthly', 'Saturday', '07:30', 'Monthly on Saturday at 7:30 AM',
     'in_person', array['gwho:men','gdo:prayer','gdo:food','gacc:drop-in','lang:english'],
     true, false),

    ('Grupo de Jóvenes',
     'Estudio bíblico y cena para jóvenes adultos, en español. [seed]',
     v_church_id, v_user_id, 'public', 'open',
     'weekly', 'Friday', '19:00', 'Weekly on Friday at 7:00 PM',
     'in_person', array['gwho:young-adults','gdo:bible-study','gdo:fellowship','lang:spanish','gacc:newcomers'],
     true, true),

    ('Recovery & Renewal',
     'A confidential step group for anyone in recovery. Members only. [seed]',
     v_church_id, v_user_id, 'members', 'request',
     'weekly', 'Thursday', '19:30', 'Weekly on Thursday at 7:30 PM',
     'in_person', array['gdo:recovery','gwho:everyone','gacc:wheelchair','lang:english'],
     false, false),

    ('Marriage Course (Online)',
     'Eight weeks for couples, over video. No childcare needed. [seed]',
     v_church_id, v_user_id, 'public', 'request',
     'weekly', 'Wednesday', '20:00', 'Weekly on Wednesday at 8:00 PM',
     'online', array['gwho:couples','gdo:marriage','gdo:discipleship','lang:english'],
     true, false),

    ('Young Families Playgroup',
     'Toddlers, chaos, and other parents who understand. [seed]',
     v_church_id, v_user_id, 'public', 'open',
     'weekly', 'Monday', '10:00', 'Weekly on Monday at 10:00 AM',
     'in_person', array['gwho:families','gwho:parents','gdo:fellowship','gacc:childcare','gacc:sensory','lang:english'],
     true, true),

    ('Saturday Serve Team',
     'Food pantry and neighborhood work. Come once or come always. [seed]',
     v_church_id, v_user_id, 'public', 'open',
     'biweekly', 'Saturday', '09:00', 'Every other Saturday at 9:00 AM',
     'in_person', array['gdo:service','gdo:missions','gwho:everyone','gacc:drop-in','lang:english'],
     true, true),

    ('Seniors Book Club',
     'One book a month, hybrid so nobody has to drive at night. [seed]',
     v_church_id, v_user_id, 'public', 'open',
     'monthly', 'Wednesday', '14:00', 'Monthly on Wednesday at 2:00 PM',
     'hybrid', array['gwho:seniors','gdo:books','gdo:fellowship','gacc:wheelchair','gacc:asl','lang:english'],
     true, true);

  get diagnostics v_inserted = row_count;
  raise notice 'OK. % groups seeded on church %.', v_inserted, v_church_id;
  raise notice 'Formats: 6 in person, 1 online, 1 hybrid. One is members-only, so it should NOT appear signed out.';
  raise notice 'Try Groups -> By Category -> Who it is for -> Women, and What you do -> Recovery & addiction.';
end $$;

-- ---------------------------------------------------------------------
-- What went in, to check against the UI.
select name, meeting_format, visibility, join_method, group_tags
  from groups
 where description like '%[seed]%'
 order by name;

-- ---------------------------------------------------------------------
-- UNDO. Removes only these eight and nothing else:
--
--   delete from groups where description like '%[seed]%';
