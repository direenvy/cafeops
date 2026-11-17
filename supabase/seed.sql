-- Demo data for CafeOps.
--
-- Idempotent: every insert is an upsert keyed on a natural unique column, so
-- this file can be re-run against an existing database without duplicating
-- anything. No UUIDs are hardcoded; rows are linked by looking names back up.
--
-- Users are NOT seeded here. Supabase auth owns auth.users, so accounts are
-- created through sign-up (or the dashboard) and then promoted; see
-- docs/SETUP.md for the two commands that do it.

-- ------------------------------------------------------------- suppliers --

insert into public.suppliers (name, contact_name, contact_email, phone, notes)
values
    ('Kedai Kopi Supply Co', 'Amir Hassan',   'orders@kopisupply.example',  '+60 3-2142 8800', 'Beans and tea, delivers Tuesdays and Fridays.'),
    ('Fresh Dairy Sdn Bhd',  'Lim Wei Ling',  'sales@freshdairy.example',   '+60 3-7955 1200', 'Milk and cream, next-day delivery before 7am.'),
    ('Pantry Basics',        'Nurul Aina',    'hello@pantrybasics.example', '+60 3-8023 4567', 'Dry goods, syrups, packaging.')
on conflict (name) do update
    set contact_name  = excluded.contact_name,
        contact_email = excluded.contact_email,
        phone         = excluded.phone,
        notes         = excluded.notes;

-- ----------------------------------------------------------- ingredients --

insert into public.ingredients (name, unit, stock_qty, reorder_level, cost_per_unit, supplier_id)
select v.name, v.unit, v.stock_qty, v.reorder_level, v.cost_per_unit, s.id
from (values
    ('Espresso beans',   'g',    8000, 2000, 0.0850, 'Kedai Kopi Supply Co'),
    ('Decaf beans',      'g',    1200,  800, 0.0950, 'Kedai Kopi Supply Co'),
    ('Black tea leaves', 'g',    1500,  500, 0.0600, 'Kedai Kopi Supply Co'),
    ('Matcha powder',    'g',     420,  300, 0.4200, 'Kedai Kopi Supply Co'),
    ('Chocolate powder', 'g',     900,  400, 0.1800, 'Pantry Basics'),
    ('Fresh milk',       'ml',  24000, 8000, 0.0062, 'Fresh Dairy Sdn Bhd'),
    ('Oat milk',         'ml',   6000, 4000, 0.0145, 'Fresh Dairy Sdn Bhd'),
    ('Whipping cream',   'ml',   2000, 1500, 0.0210, 'Fresh Dairy Sdn Bhd'),
    ('Vanilla syrup',    'ml',   1800,  600, 0.0180, 'Pantry Basics'),
    ('Caramel syrup',    'ml',    900,  600, 0.0190, 'Pantry Basics'),
    ('Sugar',            'g',    5000, 1500, 0.0040, 'Pantry Basics'),
    ('Ice',              'g',   20000, 5000, 0.0008, 'Pantry Basics'),
    ('Croissant',        'pc',       9,   12, 2.4000, 'Pantry Basics'),
    ('Banana bread',     'pc',      14,    8, 2.1000, 'Pantry Basics'),
    ('Bagel',            'pc',       6,   10, 1.9000, 'Pantry Basics'),
    ('Cream cheese',     'g',     800,  400, 0.0320, 'Fresh Dairy Sdn Bhd')
) as v (name, unit, stock_qty, reorder_level, cost_per_unit, supplier_name)
join public.suppliers s on s.name = v.supplier_name
on conflict (name) do update
    set unit          = excluded.unit,
        stock_qty     = excluded.stock_qty,
        reorder_level = excluded.reorder_level,
        cost_per_unit = excluded.cost_per_unit,
        supplier_id   = excluded.supplier_id;

-- Croissant and Bagel are seeded below their reorder level on purpose, so the
-- low-stock screen has something to show the moment the app is opened.

-- ------------------------------------------------------------ menu groups --

insert into public.menu_categories (name, sort_order)
values
    ('Espresso',   1),
    ('Brewed',     2),
    ('Non-coffee', 3),
    ('Food',       4)
on conflict (name) do update set sort_order = excluded.sort_order;

-- ------------------------------------------------------------- menu items --

insert into public.menu_items (category_id, name, description, price, sort_order)
select c.id, v.name, v.description, v.price, v.sort_order
from (values
    ('Espresso',   'Espresso',          'Double shot, 30ml.',                          7.00,  1),
    ('Espresso',   'Americano',          'Double shot lengthened with hot water.',      9.00,  2),
    ('Espresso',   'Flat White',         'Double shot with steamed milk, 180ml.',      12.00,  3),
    ('Espresso',   'Latte',              'Double shot with steamed milk, 240ml.',      13.00,  4),
    ('Espresso',   'Cappuccino',         'Double shot, equal milk and foam.',          12.50,  5),
    ('Espresso',   'Caramel Macchiato',  'Vanilla, milk, espresso, caramel drizzle.',  15.50,  6),
    ('Espresso',   'Iced Latte',         'Double shot over ice with cold milk.',       13.50,  7),
    ('Brewed',     'Pour Over',          'Single origin, brewed to order.',            14.00,  1),
    ('Brewed',     'Cold Brew',          'Steeped 18 hours, served over ice.',         14.50,  2),
    ('Brewed',     'English Breakfast',  'Loose-leaf black tea, pot for one.',          8.50,  3),
    ('Non-coffee', 'Matcha Latte',       'Ceremonial grade matcha with milk.',         15.00,  1),
    ('Non-coffee', 'Hot Chocolate',      'Dark chocolate with steamed milk.',          12.00,  2),
    ('Non-coffee', 'Babyccino',          'Steamed milk and foam, no coffee.',           6.00,  3),
    ('Food',       'Butter Croissant',   'Baked each morning.',                         8.50,  1),
    ('Food',       'Banana Bread',       'Toasted, with butter.',                       9.00,  2),
    ('Food',       'Bagel & Cream Cheese','Toasted sesame bagel.',                     11.00,  3)
) as v (category_name, name, description, price, sort_order)
join public.menu_categories c on c.name = v.category_name
on conflict (category_id, name) do update
    set description = excluded.description,
        price       = excluded.price,
        sort_order  = excluded.sort_order;

-- ----------------------------------------------------------------- recipes --

-- This is the table that turns a sale into a stock movement. Quantities are
-- per single serving and are what the checkout transaction multiplies out.

insert into public.recipe_items (menu_item_id, ingredient_id, qty_per_serving)
select m.id, i.id, v.qty
from (values
    ('Espresso',              'Espresso beans',   18),
    ('Americano',             'Espresso beans',   18),
    ('Flat White',            'Espresso beans',   18),
    ('Flat White',            'Fresh milk',      150),
    ('Latte',                 'Espresso beans',   18),
    ('Latte',                 'Fresh milk',      210),
    ('Cappuccino',            'Espresso beans',   18),
    ('Cappuccino',            'Fresh milk',      170),
    ('Caramel Macchiato',     'Espresso beans',   18),
    ('Caramel Macchiato',     'Fresh milk',      200),
    ('Caramel Macchiato',     'Vanilla syrup',    15),
    ('Caramel Macchiato',     'Caramel syrup',    10),
    ('Iced Latte',            'Espresso beans',   18),
    ('Iced Latte',            'Fresh milk',      150),
    ('Iced Latte',            'Ice',             120),
    ('Pour Over',             'Espresso beans',   22),
    ('Cold Brew',             'Espresso beans',   30),
    ('Cold Brew',             'Ice',             150),
    ('English Breakfast',     'Black tea leaves',  6),
    ('Matcha Latte',          'Matcha powder',     5),
    ('Matcha Latte',          'Fresh milk',      200),
    ('Hot Chocolate',         'Chocolate powder', 25),
    ('Hot Chocolate',         'Fresh milk',      210),
    ('Hot Chocolate',         'Whipping cream',   30),
    ('Babyccino',             'Fresh milk',      120),
    ('Butter Croissant',      'Croissant',         1),
    ('Banana Bread',          'Banana bread',      1),
    ('Bagel & Cream Cheese',  'Bagel',             1),
    ('Bagel & Cream Cheese',  'Cream cheese',     40)
) as v (item_name, ingredient_name, qty)
join public.menu_items  m on m.name = v.item_name
join public.ingredients i on i.name = v.ingredient_name
on conflict (menu_item_id, ingredient_id) do update
    set qty_per_serving = excluded.qty_per_serving;
