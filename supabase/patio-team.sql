begin;
create schema patio;
revoke all on schema patio from public, anon, authenticated;
create table patio.staff (user_id uuid primary key references auth.users on delete cascade);
create table patio.players (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(trim(name)) between 2 and 24),
  progress integer not null default 0 check (progress >= 0),
  rewards integer not null default 0 check (rewards >= 0)
);
create table patio.events (
  id bigint generated always as identity primary key,
  player uuid not null references patio.players,
  kind text not null check (kind in ('visit', 'redeem')),
  day date not null,
  staff_id uuid references auth.users on delete set null
);
create unique index patio_one_visit_per_day on patio.events (player, day) where kind = 'visit';

create function public.patio_team(action text, player_id uuid default null, nickname text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  caller uuid := auth.uid();
  local_day date := (now() at time zone 'America/Argentina/Cordoba')::date;
  selected_id uuid := player_id;
begin
  if caller is null or not exists (select 1 from patio.staff where user_id = caller) then
    raise exception 'Usuario sin acceso al equipo' using errcode = '42501';
  end if;

  case action
    when 'list' then null;
    when 'register' then
      if nickname is null or char_length(trim(nickname)) not between 2 and 24 then
        raise exception 'Ingresá un apodo de 2 a 24 caracteres';
      end if;
      insert into patio.players (name) values (trim(nickname)) returning id into selected_id;
    when 'visit' then
      if not exists (select 1 from patio.players where id = player_id) then
        raise exception 'No se encontró el jugador';
      end if;
      insert into patio.events (player, kind, day, staff_id)
        values (player_id, 'visit', local_day, caller)
        on conflict (player, day) where kind = 'visit' do nothing;
      if not found then raise exception 'Ya tiene una visita registrada hoy'; end if;
      update patio.players set progress = progress + 1 where id = player_id;
    when 'redeem' then
      update patio.players set progress = progress - 10, rewards = rewards + 1
        where id = player_id and progress >= 10;
      if not found then raise exception 'El jugador no tiene un café disponible'; end if;
      insert into patio.events (player, kind, day, staff_id) values (player_id, 'redeem', local_day, caller);
    else raise exception 'Acción inválida';
  end case;

  return jsonb_build_object(
    'selected', selected_id,
    'day', local_day,
    'players', coalesce((
      select jsonb_agg(to_jsonb(p) || jsonb_build_object(
        'lastVisit', coalesce(stats.last_visit::text, ''),
        'monthVisits', stats.month_visits
      ) order by p.name, p.id)
      from patio.players p
      left join lateral (
        select max(e.day) as last_visit,
               count(*) filter (where e.day >= date_trunc('month', local_day::timestamp)::date) as month_visits
        from patio.events e where e.player = p.id and e.kind = 'visit'
      ) stats on true
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function public.patio_team(text, uuid, text) from public, anon, authenticated;
grant execute on function public.patio_team(text, uuid, text) to authenticated;
commit;
