-- Blocked accounts: listing them, so a block can be undone.
--
-- WHY AN RPC AND NOT A SELECT. `blocks_select` already lets a user read their
-- own block rows, but those rows carry ids and nothing else, and the obvious
-- join is closed off by design:
--
--   create policy profiles_select on public.profiles for select to authenticated
--     using (auth.uid() is not null and not app.blocked_with(id));
--
-- Blocking is mutual invisibility, so the moment you block someone their
-- profile stops being readable *to you as well*. A client-side join therefore
-- returns a list of bare UUIDs — which is why the app has had `block` and
-- `unblock` since Phase 24 and no way to see who is blocked. A user could
-- block by accident and never undo it.
--
-- This function is the narrow exception: SECURITY DEFINER, and it discloses
-- only the handle and display name of people **the caller themselves blocked**.
-- That is information the caller already had at the moment they blocked them,
-- so it leaks nothing new, and it stays scoped by `blocker_id = auth.uid()`
-- rather than trusting an argument.

create or replace function public.blocked_accounts()
returns table (
  id           uuid,
  handle       text,
  display_name text,
  avatar_url   text,
  is_private   boolean,
  created_at   timestamptz
)
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select p.id, p.handle, p.display_name, p.avatar_url, p.is_private, p.created_at
  from public.blocks b
  join public.profiles p on p.id = b.blocked_id
  where b.blocker_id = auth.uid()
  order by b.created_at desc
$$;

revoke all on function public.blocked_accounts() from public;
grant execute on function public.blocked_accounts() to authenticated;

comment on function public.blocked_accounts() is
  'People the caller has blocked. SECURITY DEFINER because profiles_select '
  'hides blocked profiles from the blocker too, which would otherwise make '
  'unblocking impossible. Scoped to auth.uid(); discloses nothing the caller '
  'did not already know.';
