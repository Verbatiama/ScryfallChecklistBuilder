create table if not exists public.cards (
  id               uuid primary key,
  name             text not null,
  set_name         text,
  regular_price    numeric,
  foil_price       numeric,
  etched_price     numeric,
  released_at      date,
  collector_number integer,
  image_grid       text,   -- image_uris.grid
  image_display    text,   -- image_uris.display
  card_faces       jsonb   -- array of face objects, null for single-faced cards
);
CREATE INDEX IF NOT EXISTS card_name_index
ON public.cards (name);

create table if not exists public.card_ownership (
  id          uuid not null references public.cards (id),
  quantity    integer not null default 0 check (quantity >= 0),
  is_specific boolean not null default false,
  foiling     text not null default 'nonfoil' check (foiling in ('nonfoil', 'foil', 'etched')),
  primary key (id, foiling)
);
CREATE INDEX IF NOT EXISTS card_ownership_quantity_index
ON public.card_ownership (quantity);
