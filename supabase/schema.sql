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
CREATE INDEX card_name_index
ON public.cards (name); 