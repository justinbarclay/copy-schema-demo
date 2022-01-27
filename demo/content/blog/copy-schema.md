+++
title = "How I sped up demo data generation by 97%"
author = "Justin Barclay"
date = 2022-01-25
+++

> This blog is meant as a playground. I find it best to play with code
> and see how it really works. In fact, that was most of the impetus for
> writing this in general; I wrote it as I explored and tried to
> understand the function. As such, I've broken out <u>most</u> of the
> SQL so that you can paste it in a psql REPL and play around with it.
> Or if you're a cool kid, like me 😎, you can read use this as a
> literate playground in Emacs and org-mode.

## …or how I chose to copy data instead of generating it

TLDR; Move from ruby and rails to SQL

<img src="https://www.publicdomainpictures.net/pictures/20000/velka/surprise-surprise.jpg" title="A woman feigning surprise" alt="&quot;A woman feigning surprise&quot;" width="400" />

# Why work on this?

For a project at work, I was working on a system that would seed a
schema with a large set of data for each system's new user. Why each
user got their own schema isn't that important. What was important was
that this operation would take 15 minutes in our production environment
and, on my dev machine, 30 minutes in a development. We eventually did
some optimizations to the process where instead of inserting data one
query at a time, we would bulk insert data, which easily shaved our
times in half. But this wasn't enough for me, and I felt like we could
do better.

> I can hear you saying… "30 minutes? That's insane. How did you let it
> get so bad?" Look, mistakes were made, OK? But I am trying to learn
> from them out in the open. And in this case, I'm looking to take you
> along this specifically painful journey.

So, knowing that this could be done better, I did some research. Can we
move a lot of this initial logic from Ruby to SQL somehow? I thought
about just generating all the seed data in pure SQL and running those
seed files whenever we needed to seed a schema. That seemed messy and
unmaintainable, not only because I like maintaining Ruby over SQL but
because we had some highly related data, which would mean importing some
of our business logic into these seed files to maintain those
relationships.

Instead, I chose to dive deeper. Eventually, that led me on a short
journey onto the PostgreSQL wiki. I found an
[article](https://wiki.postgresql.org/wiki/Clone_schema) that talked
about cloning the data from one schema onto another schema. I thought
that was brilliant. We could maintain our seed data generation process
in Ruby, import it into a demo data schema, and then clone from that
schema whenever we instantiated a new schema for a user. And this
article was really close to what I wanted, but it did not clone metadata
about those tables. So, that meant that we were missing essential things
like sequences and foreign key relations when we cloned. Luckily this
article referenced a more complete [mailing list
post](https://www.postgresql.org/message-id/CANu8FiyJtt-0q%3DbkUxyra66tHi6FFzgU8TqVR2aahseCBDDntA%40mail.gmail.com)
that goes over how to copy all the data, including metadata, from a
source schema into a brand new destination schema.

# Using Pure SQL to Copy

When I started this adventure in optimization, I knew very little about
SQL and less so the variant we use, PSQL. I knew enough to write some
select statements and maybe do a join or two. But I never really
considered it a Turing Complete language 🤯. I mean… It's not pretty, but
it works.

Now, I had a pretty good idea of what I wanted to do from a high level.
We want to use a schema, called `demo`, to cache any demo data
generation. Then, when we want to populate an account schema with demo
data, we copy data from the `demo` schema into the client schema.

I knew that the function presented on that mailing list was supposed to
do what I wanted. But I understood almost none of the code. What sort of
developer would I be if I blindly copied and pasted this code into
production? So, instead, I read through this code line by line, and I
teased it apart until I could understand it. Now, I want to explain this
code very explicitly to you. You. My one reader. I mean, how else can
you know you know something unless you explain it to someone else?

## Syntax Preamble

Before I scare you with a lovecraftian horror of SQL, a 200 line
function cloning one schema into a brand new schema, I need to lay some
groundwork. I said you need to know `SELECT` and `INSERT` but now I need
to talk to you about functions. This whole mess of an article is based
on SQL functions. You should know what they are, what they look like,
what part of your brain they like to gnaw on at 3 am.

> If a horror monster does not go after the amydala first, the fear
> centre of the brain, they're doing it wrong.

### SQL Functions

Outlined below is a simple version of the function syntax. Some items
are optional, like, you don't need to have an `OR` or a `REPLACE`, you
don't need to have any arguments, and you don't have to declare any
variables.

You have to say you're creating a function with some name and that it
has a body, and then you can do 0 or more things in that body.

``` sql
CREATE OR REPLACE FUNCTION demo_func(

    source_schema text
)
  RETURNS void AS
$BODY$

DECLARE
  src_oid          oid;

BEGIN
--  ...
END;
$BODY$
```

You can also have anonymous functions, where they operate just like a
regular function but lack a name, arguments or the ability to return
anything. Anonymous functions are suitable for when you need to do some
work, and you need the full power of the PL/pgSQL language (loops,
conditionals, logs/errors), but you don't need to name it or return
anything.

``` sql
do $$
DECLARE
  src_oid oid;
BEGIN
-- ...
END
$$;
```

### For loops!

Like most modern languages, PL/pgSQL has `for loops`. However, it does
have a restriction, loops can only run within function calls.

So to write a for loop in an anonymous function, it would look something
like this:

``` SQL
do $$
BEGIN
 FOR counter IN 1..5 LOOP
   RAISE NOTICE 'Counter: %', counter;
   END LOOP;
 END
$$;
```

If you copy and paste this into a PSQL REPL, you would get output like
below:

``` SQL
NOTICE:  Counter: 1
NOTICE:  Counter: 2
NOTICE:  Counter: 3
NOTICE:  Counter: 4
NOTICE:  Counter: 5
```

For loops, in general, can work across an iterable item, be it a range,
array, or query results.

## Love and War and Cthulu

For those who just want to see and play with occult artifacts before
they understand them, here you are. Though I warn you, this incantation
may not summon Cthulu but it probably would summon something like
Azathoth.

``` sql
-- Function: clone_schema(text, text)

-- DROP FUNCTION clone_schema(text, text);

CREATE OR REPLACE FUNCTION clone_schema(
    source_schema text,
    dest_schema text,
    include_recs boolean)
  RETURNS void AS
$BODY$

--  This function will clone all sequences, tables, data, views & functions from any existing schema to a new one
-- SAMPLE CALL:
-- SELECT clone_schema('public', 'new_schema', TRUE);

DECLARE
  src_oid          oid;
  tbl_oid          oid;
  func_oid         oid;
  object           text;
  buffer           text;
  srctbl           text;
  default_         text;
  column_          text;
  qry              text;
  dest_qry         text;
  v_def            text;
  seqval           bigint;
  sq_last_value    bigint;
  sq_max_value     bigint;
  sq_start_value   bigint;
  sq_increment_by  bigint;
  sq_min_value     bigint;
  sq_cache_value   bigint;
  sq_log_cnt       bigint;
  sq_is_called     boolean;
  sq_is_cycled     boolean;
  sq_cycled        char(10);
BEGIN

-- Check that source_schema exists
  SELECT oid INTO src_oid
    FROM pg_namespace
   WHERE nspname = quote_ident(source_schema);
  IF NOT FOUND
    THEN 
    RAISE NOTICE 'source schema % does not exist!', source_schema;
    RETURN ;
      END IF;

  -- Check that dest_schema does not yet exist
  PERFORM nspname 
    FROM pg_namespace
   WHERE nspname = quote_ident(dest_schema);
  IF FOUND
    THEN 
    RAISE NOTICE 'dest schema % already exists!', dest_schema;
    RETURN ;
  END IF;

  EXECUTE 'CREATE SCHEMA ' || quote_ident(dest_schema) ;

  -- Create sequences
  -- TODO: Find a way to make this sequence's owner is the correct table.
  FOR object IN
    SELECT sequence_name::text 
      FROM information_schema.sequences
      WHERE sequence_schema = quote_ident(source_schema)
  LOOP
    EXECUTE 'CREATE SEQUENCE ' || quote_ident(dest_schema) || '.' || quote_ident(object);
    srctbl := quote_ident(source_schema) || '.' || quote_ident(object);

    EXECUTE 'SELECT last_value, max_value, start_value, increment_by, min_value, cache_value, log_cnt, is_cycled, is_called 
              FROM ' || quote_ident(source_schema) || '.' || quote_ident(object) || ';' 
              INTO sq_last_value, sq_max_value, sq_start_value, sq_increment_by, sq_min_value, sq_cache_value, sq_log_cnt, sq_is_cycled, sq_is_called ; 

    IF sq_is_cycled 
      THEN 
        sq_cycled := 'CYCLE';
    ELSE
        sq_cycled := 'NO CYCLE';
    END IF;

    EXECUTE 'ALTER SEQUENCE '   || quote_ident(dest_schema) || '.' || quote_ident(object) 
            || ' INCREMENT BY ' || sq_increment_by
            || ' MINVALUE '     || sq_min_value 
            || ' MAXVALUE '     || sq_max_value
            || ' START WITH '   || sq_start_value
            || ' RESTART '      || sq_min_value 
            || ' CACHE '        || sq_cache_value 
            || sq_cycled || ' ;' ;

    buffer := quote_ident(dest_schema) || '.' || quote_ident(object);
    IF include_recs 
        THEN
            EXECUTE 'SELECT setval( ''' || buffer || ''', ' || sq_last_value || ', ' || sq_is_called || ');' ; 
    ELSE
            EXECUTE 'SELECT setval( ''' || buffer || ''', ' || sq_start_value || ', ' || sq_is_called || ');' ;
    END IF;

  END LOOP;

-- Create tables 
  FOR object IN
    SELECT TABLE_NAME::text 
      FROM information_schema.tables 
     WHERE table_schema = quote_ident(source_schema)
       AND table_type = 'BASE TABLE'

  LOOP
    buffer := dest_schema || '.' || quote_ident(object);
    EXECUTE 'CREATE TABLE ' || buffer || ' (LIKE ' || quote_ident(source_schema) || '.' || quote_ident(object) 
        || ' INCLUDING ALL)';

    IF include_recs 
      THEN 
      -- Insert records from source table
      EXECUTE 'INSERT INTO ' || buffer || ' SELECT * FROM ' || quote_ident(source_schema) || '.' || quote_ident(object) || ';';
    END IF;

    FOR column_, default_ IN
      SELECT column_name::text, 
             REPLACE(column_default::text, source_schema, dest_schema) 
        FROM information_schema.COLUMNS 
       WHERE table_schema = dest_schema 
         AND TABLE_NAME = object 
         AND column_default LIKE 'nextval(%' || quote_ident(source_schema) || '%::regclass)'
    LOOP
      EXECUTE 'ALTER TABLE ' || buffer || ' ALTER COLUMN ' || column_ || ' SET DEFAULT ' || default_;
    END LOOP;

  END LOOP;

--  add FK constraint
  FOR qry IN
    SELECT 'ALTER TABLE ' || quote_ident(dest_schema) || '.' || quote_ident(rn.relname) 
                          || ' ADD CONSTRAINT ' || quote_ident(ct.conname) || ' ' || pg_get_constraintdef(ct.oid) || ';'
      FROM pg_constraint ct
      JOIN pg_class rn ON rn.oid = ct.conrelid
     WHERE connamespace = src_oid
       AND rn.relkind = 'r'
       AND ct.contype = 'f'

    LOOP
      EXECUTE qry;

    END LOOP;


-- Create views 
  FOR object IN
    SELECT table_name::text,
           view_definition 
      FROM information_schema.views
     WHERE table_schema = quote_ident(source_schema)

  LOOP
    buffer := dest_schema || '.' || quote_ident(object);
    SELECT view_definition INTO v_def
      FROM information_schema.views
     WHERE table_schema = quote_ident(source_schema)
       AND table_name = quote_ident(object);

    EXECUTE 'CREATE OR REPLACE VIEW ' || buffer || ' AS ' || v_def || ';' ;

  END LOOP;

-- Create functions 
  FOR func_oid IN
    SELECT oid
      FROM pg_proc 
     WHERE pronamespace = src_oid

  LOOP      
    SELECT pg_get_functiondef(func_oid) INTO qry;
    SELECT replace(qry, source_schema, dest_schema) INTO dest_qry;
    EXECUTE dest_qry;

  END LOOP;

  RETURN; 

END;

$BODY$
  LANGUAGE plpgsql VOLATILE
  COST 100;
ALTER FUNCTION clone_schema(text, text, boolean)
  OWNER TO postgres;
```

> The function above is slightly modified from the version found on the
> mailing list. Mainly, it has been modified to work in modern versions
> of Postres IE. 10 and above.

Woh, insane, right? That's a lot of SQL, and there are words like CREATE
and OR and LOOP in there. I need to step back and go section by section
to grasp this.

> I am done with the jokes and the Cthulu and the like. This is a
> serious learning article, we need to be serious to be taken serious.

# Let's break it down

## Metaprogramming in Postgres

``` SQL
SELECT * FROM pg_namespace;
```

Postgres keeps a table of information about itself and its state, and
they call the collection of metadata [systems
catalogue](https://www.postgresql.org/docs/13/catalogs.html). Generally,
these tables are prefixed with `pg`. For example,
[pg_namespace](https://www.postgresql.org/docs/13/catalog-pg-namespace.html)
is a table that contains information about all schemas stored in the
database.

## Operating on Schemas

I assume you know about Schemas because this is a blog post on how to
clone one schema to another. However, if you're new to SQL or have never
needed to concern yourself with schemas before, visit
[here](https://www.postgresql.org/docs/current/ddl-schemas.) to find out
more.

### Check for schema existence

Knowing about the existence of `pg_namespace` gives us the ability to
understand the first section of code:

``` SQL
-- Check that source_schema exists
    SELECT oid INTO src_oid
      FROM pg_namespace
     WHERE nspname = quote_ident(source_schema);
    IF NOT FOUND
      THEN 
      RAISE NOTICE 'source schema % does not exist!', source_schema;
      RETURN;
        END IF;

    -- Check that dest_schema does not yet exist
    PERFORM nspname 
      FROM pg_namespace
     WHERE nspname = quote_ident(dest_schema);
    IF FOUND
      THEN 
      RAISE NOTICE 'dest schema % already exists!', dest_schema;
      RETURN ;
    END IF;

    EXECUTE 'CREATE SCHEMA ' || quote_ident(dest_schema) ;
```

Unfortunately, we can't really run that as pure SQL in its current form.
So instead, we need to make it a function so we can normalize the
results:

``` SQL
CREATE OR REPLACE FUNCTION check_existence(
  source_schema text)
  RETURNS bool AS $BODY$
BEGIN

 PERFORM oid
    FROM pg_namespace
   WHERE nspname = quote_ident(source_schema);
  IF NOT FOUND
  THEN
    RAISE NOTICE 'source schema % does not exist!', source_schema;
    RETURN false;
  ELSE
    RETURN true;
  END IF;
END;
$BODY$

LANGUAGE plpgsql VOLATILE
COST 100;
```

| CREATE FUNCTION |
|-----------------|

And then, we can test it to see if a schema does exist:

``` SQL
SELECT check_existence('public');
```

We can also check for the non-existence of a schema:

``` SQL
SELECT check_existence('backup');
```

||
||

### Creating a schema

Great, now we know that the `backup` schema doesn't exist. Let's make
one. Luckily, creating a schema is pretty easy:

``` SQL
CREATE SCHEMA backup;
```

Now we can use our function to verify:

``` SQL
SELECT check_existence('backup');
```

## Sequences

The next step in copying one schema to another is to copy all of the
[Sequences](https://www.postgresql.org/docs/14/sql-createsequence.html):

``` SQL
FOR object IN
SELECT
  sequence_name::text
FROM
  information_schema.sequences
WHERE
  sequence_schema = quote_ident(source_schema)
  LOOP
    EXECUTE 'CREATE SEQUENCE ' | | quote_ident(dest_schema) | | '.' | | quote_ident(object);

srctbl: = quote_ident(source_schema) | | '.' | | quote_ident(object);

seq_query: = format('SELECT max_value, start_value, increment_by, min_value, cache_size, cycle FROM pg_sequences
                        WHERE sequencename = %L AND schemaname = %L ;', object, source_schema);

EXECUTE seq_query INTO sq_max_value,
sq_start_value,
sq_increment_by,
sq_min_value,
sq_cache_value,
sq_is_cycled;

seq_query: = format('SELECT last_value, log_cnt, is_called FROM %s.%s;', source_schema, object);

EXECUTE seq_query INTO sq_last_value,
sq_log_cnt,
sq_is_called;

IF sq_is_cycled THEN
  sq_cycled: = 'CYCLE';

ELSE
  sq_cycled: = 'NO CYCLE';

END IF;

seq_query: = format('ALTER SEQUENCE %s.%s INCREMENT BY %s MINVALUE %s MAXVALUE %s START WITH %s RESTART %s CACHE %s %s ;', quote_ident(dest_schema), quote_ident(object), sq_increment_by, sq_min_value, sq_max_value, sq_start_value, sq_min_value, sq_cache_value, sq_cycled);

EXECUTE seq_query;

buffer: = quote_ident(dest_schema) | | '.' | | quote_ident(object);

IF include_recs THEN
  EXECUTE 'SELECT setval( ''' | | buffer | | ''', ' | | sq_last_value | | ', ' | | sq_is_called | | ');';

ELSE
  EXECUTE 'SELECT setval( ''' | | buffer | | ''', ' | | sq_start_value | | ', ' | | sq_is_called | | ');';

END IF;

END LOOP;
```

### What is a Sequence

A Sequence is a special table that generates some sequence of numbers.
For instance, Sequences are often used for generating the index values
for a table.

### Copying Sequence and Values

When copying sequences, we're looking to:

1.  Get all sequence names from the source schema
2.  Copy selected sequence names into dest schema
3.  Populate them with metadata from source sequences
4.  Update destination schema number to match source schema numbers

<!-- -->

1.  1\. Get All Sequence Names

    If we query Postgres for all sequences attached to the public table:

    ``` SQL
    SELECT sequence_name::text 
     FROM information_schema.sequences
     WHERE sequence_schema = quote_ident('public')
    ```

    We find that we have 7 entries:

    | sequence_name                         |
    |---------------------------------------|
    | users_id_seq                          |
    | active_storage_attachments_id_seq     |
    | microposts_id_seq                     |
    | active_storage_blobs_id_seq           |
    | active_storage_variant_records_id_seq |
    | relationships_id_seq                  |

    Before we can proceed, we need to ensure our new schema doesn't have
    any sequences in it:

    ``` SQL
    SELECT
      sequence_name::text
    FROM
      information_schema.sequences
    WHERE
      sequence_schema = quote_ident('backup')
    ```

    Beautiful:

    | sequence_name |
    |---------------|

2.  2\. Create Sequence

    Creating a list of sequences looks like this:

    ``` SQL
    FOR object IN
    SELECT
      sequence_name::text
    FROM
      information_schema.sequences
    WHERE
      sequence_schema = quote_ident(source_schema)
      LOOP
        EXECUTE 'CREATE SEQUENCE ' || quote_ident(dest_schema) || '.' || quote_ident(object);

    END LOOP;
    ```

    Generally, in a schema, there are a lot of sequences. One for each
    table with an index. So, let's zoom in on one sequence and follow it
    through the process.

    From the code above, where you see `object`, we will replace it with
    `microposts_id_seq'`, one of the values from the above select
    statement.

    ``` sql
    CREATE SEQUENCE backup.microposts_id_seq;
    ```

    And let's take a look at what we made

    ``` sql
    SELECT * FROM backup.microposts_id_seq;
    ```

    We made a table that stores values for last_value, log_cnt[1], and
    is_called[2].

3.  3\. Copy Sequence Values

    Now we're going to fake it a little bit to see what the following
    statement is doing more easily.

    We can translate:

    ``` sql
    seq_query: = format('SELECT max_value, start_value, increment_by, min_value, cache_size, cycle FROM pg_sequences
      WHERE sequencename = %L AND schemaname = %L ;', object, source_schema);

    EXECUTE seq_query INTO sq_max_value,
    sq_start_value,
    sq_increment_by,
    sq_min_value,
    sq_cache_value,
    sq_is_cycled;
    ```

    To:

    ``` sql
    SELECT
      max_value AS sq_max_value,
      start_value AS sq_start_value,
      increment_by AS sq_increment_by,
      min_value AS sq_min_value,
      cache_size AS sq_cache_value,
      CYCLE AS sq_is_cycled
    FROM
      pg_sequences
    WHERE
      sequencename = 'microposts_id_seq'
      AND schemaname = 'public';
    ```

    Which gets us a nice little table:

    | sq_max_value        | sq_start_value | sq_increment_by | sq_min_value | sq_cache_value | sq_is_cycled |
    |---------------------|----------------|-----------------|--------------|----------------|--------------|
    | 9223372036854775807 | 1              | 1               | 1            | 1              | f            |

    Now because of how SQL works, we have to convert data. So we
    translate the value `sq_is_cycled` from a boolean to a string.

    ``` SQL
    IF sq_is_cycled THEN
      sq_cycled := 'CYCLE';

    ELSE
      sq_cycled := 'NO CYCLE';

    END IF;
    ```

    If we go to the table above, we can see that `sq_is_cycled` is
    false, which means `sq_cycled` is set to `'NO CYCLE'`.

    So now we want to copy over the data from `public.microposts_id_seq`
    to `backup.microposts_id_seq`

    ``` sql
    ALTER SEQUENCE backup.microposts_id_seq
      INCREMENT BY 1
      MINVALUE 1
      MAXVALUE 9223372036854775807 START WITH 1 RESTART 1
      CACHE 1 NO CYCLE;
    ```

    Now, we can run the same select query to get data about a sequence
    to verify that we have successfully cloned `microposts_id_seq` into
    `backup`

    ``` sql
    SELECT
      max_value AS sq_max_value,
      start_value AS sq_start_value,
      increment_by AS sq_increment_by,
      min_value AS sq_min_value,
      cache_size AS sq_cache_value,
      CYCLE AS sq_is_cycled
    FROM
      pg_sequences
    WHERE
      sequencename = 'microposts_id_seq'
      AND schemaname = 'backup';

    ```

4.  4\. Update sequence to match current values

    Then because we're cloning both meta information and records
    themselves, we want to make sure our sequence values align with the
    `public`'s sequence values.

    ``` sql
    seq_query := format('SELECT last_value, log_cnt, is_called FROM %s.%s;', source_schema, object);

    EXECUTE seq_query INTO sq_last_value,
    sq_log_cnt,
    sq_is_called;
    ```

    So, now we need to get the current state of the sequence for
    microposts_id_seq

    ``` sql
    SELECT
      last_value AS sq_last_value,
      log_cnt AS sq_log_cnt,
      is_called AS sq_is_called
    FROM
      public.microposts_id_seq;
    ```

    and update the `backup` schema

    ``` sql
    EXECUTE 'SELECT setval( ''' || buffer || ''', ' || sq_last_value || ', ' || sq_is_called || ');'
    ```

    Which we can trivially translate to:

    ``` SQL
    SELECT
      setval('backup.microposts_id_seq', 300, TRUE);
    ```

    1.  Let's quickly verify our work

        If we call nextval on `public.microposts_id_seq` and
        `backup.microposts_id_seq` they should produce the same results.

        ``` sql
        SELECT
          nextval('public.microposts_id_seq');
        ```

        ``` sql
        SELECT
          nextval('backup.microposts_id_seq');
        ```

5.  Playground

    And now we just do that like… 50 more times.

    ``` sql
    DO $$
    DECLARE
      source_schema text;
      dest_schema text;
      seq_query text;
      buffer text;
      srctbl text;
      object text;
      sq_max_value bigint;
      sq_start_value bigint;
      sq_increment_by bigint;
      sq_min_value bigint;
      sq_cache_value bigint;
      sq_is_cycled bool;
      sq_last_value bigint;
      sq_log_cnt bigint;
      sq_is_called bool;
      sq_cycled text;
      include_recs bool;
    BEGIN
      include_recs := TRUE;
      source_schema := 'public';
      dest_schema := 'backup';
      FOR object IN
      SELECT
        sequence_name::text
      FROM
        information_schema.sequences
      WHERE
        sequence_schema = quote_ident(source_schema)
        LOOP
          EXECUTE 'CREATE SEQUENCE ' || quote_ident(dest_schema) || '.' || quote_ident(object);
          srctbl := quote_ident(source_schema) || '.' || quote_ident(object);
          seq_query := format('SELECT max_value, start_value, increment_by, min_value, cache_size, cycle FROM pg_sequences
                            WHERE sequencename = %L AND schemaname = %L ;', object, source_schema);
          EXECUTE seq_query INTO sq_max_value,
          sq_start_value,
          sq_increment_by,
          sq_min_value,
          sq_cache_value,
          sq_is_cycled;
          seq_query := format('SELECT last_value, log_cnt, is_called FROM %s.%s;', source_schema, object);
          EXECUTE seq_query INTO sq_last_value,
          sq_log_cnt,
          sq_is_called;
          IF sq_is_cycled THEN
            sq_cycled := 'CYCLE';
          ELSE
            sq_cycled := 'NO CYCLE';
          END IF;
          seq_query := format('ALTER SEQUENCE %s.%s INCREMENT BY %s MINVALUE %s MAXVALUE %s START WITH %s RESTART %s CACHE %s %s ;', quote_ident(dest_schema), quote_ident(object), sq_increment_by, sq_min_value, sq_max_value, sq_start_value, sq_min_value, sq_cache_value, sq_cycled);
          EXECUTE seq_query;
          buffer := quote_ident(dest_schema) || '.' || quote_ident(object);
          IF include_recs THEN
            EXECUTE 'SELECT setval( ''' || buffer || ''', ' || sq_last_value || ', ' || sq_is_called || ');';
          ELSE
            EXECUTE 'SELECT setval( ''' || buffer || ''', ' || sq_start_value || ', ' || sq_is_called || ');';
          END IF;
        END LOOP;
    END
    $$;
    ```

## Tables

For step 2 of our 5 step plan, we need to copy tables. This includes
their data and metadata. The section of the `clone_schema` function that
deals with cloning tables is:

``` SQL
FOR object IN
    SELECT TABLE_NAME::text 
      FROM information_schema.tables 
     WHERE table_schema = quote_ident(source_schema)
       AND table_type = 'BASE TABLE'

  LOOP
    buffer := dest_schema || '.' || quote_ident(object);
    EXECUTE 'CREATE TABLE ' || buffer || ' (LIKE ' || quote_ident(source_schema) || '.' || quote_ident(object) 
        || ' INCLUDING ALL)';

    IF include_recs 
      THEN 
      -- Insert records from source table
      EXECUTE 'INSERT INTO ' || buffer || ' SELECT * FROM ' || quote_ident(source_schema) || '.' || quote_ident(object) || ';';
    END IF;

    FOR column_, default_ IN
      SELECT column_name::text, 
             REPLACE(column_default::text, source_schema, dest_schema) 
        FROM information_schema.COLUMNS 
       WHERE table_schema = dest_schema 
         AND TABLE_NAME = object 
         AND column_default LIKE 'nextval(%' || quote_ident(source_schema) || '%::regclass)'
    LOOP
      EXECUTE 'ALTER TABLE ' || buffer || ' ALTER COLUMN ' || column_ || ' SET DEFAULT ' || default_;
    END LOOP;

  END LOOP;
```

Luckily, this section of the `clone_schema` function seems a lot
simpler. Well, at least for me, but maybe that's because I am performing
simple select or insert operations on tables any time I play in SQL.

### Copying table structure and data

Reading through the SQL above, we can see 4 main tasks ahead of us:

1.  Get all the tables of interest
2.  Create the tables in the new schema
3.  Copy data from the source schema's tables into the new schema's
    tables
4.  Update Default/Sequence values for appropriate columns

<!-- -->

1.  1\. Get all tables

    We want to iterate over all the tables in a schema. But how do we
    get that information? Luckily, Postgres has meta-programming
    facilities based around schema's called
    [information_schema](https://www.postgresql.org/docs/current/information-schema.html)
    which has a
    [view](https://www.postgresql.org/docs/13/sql-createview.html)
    specifically for
    [tables](https://www.postgresql.org/docs/current/infoschema-tables.html).

    In short if we run a command like below, we can get a list of all
    table names that are in the public schema.

    ``` sql
    -- FOR OBJECT In
    SELECT
      TABLE_NAME::text
    FROM
      information_schema.tables
    WHERE
      table_schema = 'public'
      AND table_type = 'BASE TABLE'
    ```

2.  2\. Copying table structure

    Like in sequences, we will step through copying one table as an
    example of how it works across the entire system. Let's operate on
    the `microposts` table.

    It's surprisingly simple to copy table structures across schemas.
    When doing a CREATE table operation, we can interpret the following
    as "copy this table with X columns, indexes, and constraints." All
    we need are two new pieces of syntax: [LIKE and
    INCLUDING](https://www.postgresql.org/docs/current/sql-createtable.html).

    > The LIKE clause specifies a table from which the new table
    > automatically copies all column names, their data types, and their
    > not-null constraints.
    >
    > -   Postgres Documentation

    ``` sql
    CREATE TABLE backup.microposts (
      LIKE public.microposts INCLUDING ALL
    );
    ```

    We can verify that this works by seeing that the table exists but is
    void of any data:

    ``` SQL
    SELECT
      id,
      content
    FROM
      backup.microposts
    ```

3.  3\. Copy Data

    Copying data is one of the least complicated interactions we have.
    It's just a combination of INSERT and SELECT operations.

    ``` sql
    INSERT INTO backup.microposts
    SELECT * FROM
      public.microposts;
    ```

    | INSERT 0 300 |
    |--------------|

    We can admire our handiwork by using a SELECT and a [RIGHT
    JOIN](https://www.postgresql.org/docs/14/queries-table-expressions.html)
    statement to compare the two tables.

    😲

    Shocking, I know.

    ``` sql
    SELECT
      public.microposts.content AS public_content,
      public.microposts.id AS public_id,
      backup.microposts.content AS backup_content,
      backup.microposts.id AS backup_id
    FROM
      backup.microposts
      RIGHT JOIN public.microposts ON backup.microposts.id = public.microposts.id
    LIMIT 10;
    ```

4.  4\. Update Default/Sequence values for columns

    When we created the `backup.microposts` table based off of the
    `public.microposts` table it copied everything, metadata included,
    word for word. However, this introduces a problem for us when we
    need to use our sequences from earlier. It copies and references
    <u>all of</u> the old table's metadata, including the sequences
    table reference. So we need to search through the table's metadata
    and look for columns with a default value that uses sequences and
    replaces the inner text from referencing `public` to reference
    `backup`.

    We can generate a query that performs this for us

    ``` sql
    SELECT
      column_name::text,
      REPLACE(column_default::text, 'public', 'backup'),
      column_default::text
    FROM
      information_schema.COLUMNS
    WHERE
      table_schema = 'backup'
      AND TABLE_NAME = 'microposts'
      AND column_default LIKE 'nextval(%public%::regclass)'
    ```

    We can then use this information to update our apps table to
    reference the new sequences we generated.

    ``` sql
    ALTER TABLE backup.microposts
      ALTER COLUMN id SET DEFAULT nextval('backup.microposts_id_seq'::regclass);
    ```

    And if you wonder what happens when we call
    nextval('backup.microposts_id_seq'::regclass), you can play with it
    below. In my example, it generates a monotonically increasing
    number, perfect for an object id.

    ``` sql
    SELECT
      nextval('backup.microposts_id_seq'::regclass);
    ```

5.  Playground

    ``` sql
    DO $$
    DECLARE
      object text;
      buffer text;
      source_schema text;
      dest_schema text;
      include_recs bool;
      column_ text;
      default_ text;
    BEGIN
      source_schema := 'public';
      dest_schema := 'backup';
      include_recs := TRUE;
      FOR object IN
      SELECT
        TABLE_NAME::text
      FROM
        information_schema.tables
      WHERE
        table_schema = quote_ident(source_schema)
        AND table_type = 'BASE TABLE' LOOP
          buffer := dest_schema || '.' || quote_ident(object);
          EXECUTE 'CREATE TABLE ' || buffer || ' (LIKE ' || quote_ident(source_schema) || '.' || quote_ident(object) || ' INCLUDING ALL)';
          IF include_recs THEN
            -- Insert records from source table
            EXECUTE 'INSERT INTO ' || buffer || ' SELECT * FROM ' || quote_ident(source_schema) || '.' || quote_ident(object) || ';';
          END IF;
          FOR column_,
          default_ IN
          SELECT
            column_name::text,
            REPLACE(column_default::text, source_schema, dest_schema)
          FROM
            information_schema.COLUMNS
          WHERE
            table_schema = dest_schema
            AND TABLE_NAME = object
            AND column_default LIKE 'nextval(%' || quote_ident(source_schema) || '%::regclass)' LOOP
              EXECUTE 'ALTER TABLE ' || buffer || ' ALTER COLUMN ' || column_ || ' SET DEFAULT ' || default_;
            END LOOP;
        END LOOP;
    END
    $$;
    ```

## Foreign Key Constraints

Now we'll be concerned about is [foreign key
constraints](https://www.postgresql.org/docs/14/ddl-constraints.html#DDL-CONSTRAINTS-FK).
Foreign Key constraints help define and validate relationships between
tables.

``` sql
FOR qry IN
SELECT
  'ALTER TABLE ' || quote_ident(dest_schema) || '.' || quote_ident(rn.relname) || ' ADD CONSTRAINT ' || quote_ident(ct.conname) || ' ' || pg_get_constraintdef(ct.oid) || ';'
FROM
  pg_constraint ct
  JOIN pg_class rn ON rn.oid = ct.conrelid
WHERE
  connamespace = src_oid
  AND rn.relkind = 'r'
  AND ct.contype = 'f' LOOP
    EXECUTE qry;
END LOOP;

```

### Copying Constraints

1.  Go over all constraints for source schema
2.  Generate a query to create the same constraint on the destination
    schema
3.  Execute all the queries

<!-- -->

1.  0\. Get src schema oid

    Throughout the following code samples, we need to get the `oid` of
    the source table. So, unlike our main function, we don't have access
    to that `oid` as a variable. To remedy this, we replace any
    reference to `src_oid` with the query to get the `oid` at run time.

    ``` SQL
    SELECT
      oid
    FROM
      pg_namespace
    WHERE
      nspname = quote_ident('public');
    ```

2.  1\. Get all constraints for source schema

    Postgres has a catalogue called
    [pg_constraint](https://www.postgresql.org/docs/current/catalog-pg-constraint.html)
    that contains meta-information around all the constraints
    (foreign_key, primary_key, and exclusion) across the database.
    Unfortunately, that table is not sufficient to generate our query;
    we also need access to
    [pg_class](https://www.postgresql.org/docs/current/catalog-pg-class.html)
    which is a catalogue that keeps meta-information on anything that
    has a column in Postgres.

    In `pg_constraint` it a has a column called contype, that describes
    the type on constraint that the row describes. Ex:

    -   c = check constraint
    -   f = foreign key constraint
    -   p = primary key constraint
    -   u = unique constraint
    -   t = constraint trigger
    -   x = exclusion constraint

    So because we're looking for foreign key constraints, we can limit
    our query to `ct.contype = 'f'`.

    For `pg_class`, it has a column called relkind that describes the
    kind of relations that row describes. Ex:

    -   r = ordinary table
    -   i = index
    -   S = sequence
    -   t = TOAST table
    -   v = view
    -   m = materialized view
    -   c = composite type
    -   f = foreign table
    -   p = partitioned table
    -   I = partitioned index

    Because we've only really copied over tables, that's all we really
    care about for kinds of relation `rn.relkind = 'r'`.

    Putting this all together, we'd get a query like:

    ``` SQL
    SELECT
      rn.relname,
      ct.conname,
      ct.oid
    FROM
      pg_constraint ct
      JOIN pg_class rn ON rn.oid = ct.conrelid
    WHERE
      connamespace = (
        SELECT
          oid
        FROM
          pg_namespace
        WHERE
          nspname = quote_ident('public'))
      AND rn.relkind = 'r'
      AND ct.contype = 'f';
    ```

    | relname                        | conname             | oid   |
    |--------------------------------|---------------------|-------|
    | microposts                     | fk_rails_558c81314b | 16428 |
    | active_storage_attachments     | fk_rails_c3b3935057 | 16458 |
    | active_storage_variant_records | fk_rails_993965df05 | 16476 |

3.  2\. Generate a query to create constraints

    Postgres has a function,
    [pg_get_constraintdef,](https://www.postgresql.org/docs/13/functions-info.html#FUNCTIONS-INFO-CATALOG-TABLE)
    that can generate a constraint definition based on an object id.

    For example, I took a row from the constraints query above and got
    an OID of `16428`.

    ``` example
    | relname                | conname             |   oid |
    |------------------------+---------------------+-------|
    | microposts             | fk_rails_d296c622dc | 16428 |
    ```

    If we run a select statement on that function…

    ``` sql
    SELECT pg_get_constraintdef(16428)
    ```

    We get the following definition:

    | pg_get_constraintdef                       |
    |--------------------------------------------|
    | FOREIGN KEY (user_id) REFERENCES users(id) |

    We can then put this information with the Constraints Query to
    generate the query for us:

    ``` SQL
    SELECT
      'ALTER TABLE ' || quote_ident('backup') || '.' || quote_ident(rn.relname) || ' ADD CONSTRAINT ' || quote_ident(ct.conname) || ' ' || pg_get_constraintdef(ct.oid) || ';'
    FROM
      pg_constraint ct
      JOIN pg_class rn ON rn.oid = ct.conrelid
    WHERE
      connamespace = (
        SELECT
          oid
        FROM
          pg_namespace
        WHERE
          nspname = quote_ident('public'))
      AND rn.relkind = 'r'
      AND ct.contype = 'f'
    LIMIT 1;
    ```

4.  3\. Execute generate queries

    Now, we can use a select statement to run a string as a query

    ``` SQL
    SELECT 'ALTER TABLE backup.active_storage_attachments ADD CONSTRAINT fk_rails_d296c622dc FOREIGN KEY (blob_id) REFERENCES active_storage_blobs(id);'
    ```

    Now, just do that for all foreign keys we need to update. I'll wait
    ⏰

5.  Playground :todo:still-broken:

    ``` SQL
    DO $$
    DECLARE
      qry text;
      dest_schema text;
      src_oid oid;
      source_schema text;
    BEGIN
      dest_schema = 'backup';
      source_schema = 'public';
      -- Preamble to get src_oid
      SELECT
        oid INTO src_oid
      FROM
        pg_namespace
      WHERE
        nspname = quote_ident(source_schema);
      -- the actual work
      FOR qry IN
      SELECT
        'ALTER TABLE ' || quote_ident(dest_schema) || '.' || quote_ident(rn.relname) || ' ADD CONSTRAINT ' || quote_ident(ct.conname) || ' ' || pg_get_constraintdef(ct.oid) || ';'
      FROM
        pg_constraint ct
        JOIN pg_class rn ON rn.oid = ct.conrelid
      WHERE
        connamespace = src_oid
        AND rn.relkind = 'r'
        AND ct.contype = 'f'
        LOOP
          EXECUTE qry;
        END LOOP;
    END
    $$;
    ```

## Views

In step 5, we will copy all of the views defined in the source schema
into the destination schema. If you are new to the "advanced" SQL
concept of a
[view](https://www.postgresql.org/docs/14/tutorial-views.html); it is a
way of naming a query that you expect to be running over and over again.

``` sql
FOR object IN
  SELECT table_name::text
    FROM information_schema.views
   WHERE table_schema = quote_ident(source_schema)

LOOP
  buffer := dest_schema || '.' || quote_ident(object);
  SELECT view_definition INTO v_def
    FROM information_schema.views
   WHERE table_schema = quote_ident(source_schema)
     AND table_name = quote_ident(object);

     EXECUTE 'CREATE OR REPLACE VIEW ' || buffer || ' AS ' || v_def || ';' ;

END LOOP;
```

If you have a database with views, the steps would be as follow:

1.  Loops over each view in `information_schema.views`
2.  Use the view definition that is stored in the view catalogue to
    define the view in the destination schema

Aye, but there's the rub. Our data set is basic and doesn't include
views or functions. So we'll build some as we go.

### Precursor

But before we can do that let's be absolutely sure that we don't have
any views stored in our view catalog.

``` sql
SELECT table_name::text
 FROM information_schema.views
WHERE table_schema = quote_ident('public')
```

### Creating our view

In our example, we'll create a view for all microposts created by a
particular user.

``` sql
CREATE VIEW first_users_posts AS
  SELECT content, microposts.created_at as created_at, name
      FROM microposts, users
      WHERE users.id = (SELECT id FROM users LIMIT 1)
```

| CREATE VIEW |
|-------------|

Now, lets validate that it works

``` sql
SELECT * FROM first_users_posts LIMIT 10
```

| content                              | created_at                 | name         |
|--------------------------------------|----------------------------|--------------|
| Quisquam non ut aliquid repudiandae. | 2021-12-15 05:17:48.07503  | Example User |
| Quisquam non ut aliquid repudiandae. | 2021-12-15 05:17:48.085981 | Example User |
| Quisquam non ut aliquid repudiandae. | 2021-12-15 05:17:48.093539 | Example User |
| Quisquam non ut aliquid repudiandae. | 2021-12-15 05:17:48.099877 | Example User |
| Quisquam non ut aliquid repudiandae. | 2021-12-15 05:17:48.106309 | Example User |
| Quisquam non ut aliquid repudiandae. | 2021-12-15 05:17:48.112993 | Example User |
| Vitae quisquam facilis qui vel.      | 2021-12-15 05:17:48.119943 | Example User |
| Vitae quisquam facilis qui vel.      | 2021-12-15 05:17:48.126818 | Example User |
| Vitae quisquam facilis qui vel.      | 2021-12-15 05:17:48.133882 | Example User |
| Vitae quisquam facilis qui vel.      | 2021-12-15 05:17:48.140942 | Example User |

### Collecting the views

With all the dirty work done, we need to loop over all of the views in
our catalogue. Luckily we've already seen the primary tool for that.
Again, we'll be limiting our selection to one, so it's easier to follow
along and go through this step by step.

``` sql
SELECT table_name::text
 FROM information_schema.views
WHERE table_schema = quote_ident('public')
LIMIT 1
```

| table_name        |
|-------------------|
| first_users_posts |

### Copying views

Great, we've got a view name. Now we can use that name to build up the
name of the view for the destination scheme:

``` SQL
SELECT 'backup' || '.' || quote_ident('first_users_posts');
```

| ?column?                 |
|--------------------------|
| backup.first_users_posts |

Now that we've generated the name, we need to get the view definition:

``` SQL
SELECT view_definition
  FROM information_schema.views
 WHERE table_schema = quote_ident('public')
   AND table_name = quote_ident('first_users_posts');
```

| view_definition                       |
|---------------------------------------|
| SELECT microposts.content,            |
| microposts.created_at,                |
| users.name                            |
| FROM microposts,                      |
| users                                 |
| WHERE (users.id = ( SELECT users_1.id |
| FROM users users_1                    |
| LIMIT 1));                            |

And then, finally, we can use these pieces of information to copy the
view.

``` sql
DO $$
BEGIN
  EXECUTE 'CREATE OR REPLACE VIEW ' || 'backup' || '.' || quote_ident('first_users_posts') || ' AS ' || (
    SELECT
      view_definition
    FROM
      information_schema.views
    WHERE
      table_schema = quote_ident('public')
      AND table_name = quote_ident('first_users_posts')) || ';';
END
$$;
```

### Playground

``` sql
DO $$
DECLARE
  object text;
  source_schema text;
  dest_schema text;
  buffer text;
  v_def text;
BEGIN
  source_schema := 'public';
  dest_schema := 'backup';
  FOR object IN
  SELECT
    table_name::text
  FROM
    information_schema.views
  WHERE
    table_schema = quote_ident(source_schema)
    LOOP
      buffer := dest_schema || '.' || quote_ident(object);
      SELECT
        view_definition INTO v_def
      FROM
        information_schema.views
      WHERE
        table_schema = quote_ident(source_schema)
        AND table_name = quote_ident(object);
      EXECUTE 'CREATE OR REPLACE VIEW ' || buffer || ' AS ' || v_def || ';';
    END LOOP;
END
$$;
```

## Functions

And this is where we are going to get `Meta`. We will talk about a
cloning function while dissecting our cloning function.

> For those reading this, not in 2022, Facebook recently changed their
> name to Meta, so I wanted to make a bad pun. But instead of you being
> able to chuckle at that, you now have to read this long-winded
> explanation.

Now, the final part in question that we're interested in is:

``` SQL
FOR func_oid IN
  SELECT oid
    FROM pg_proc 
   WHERE pronamespace = src_oid

LOOP      
  SELECT pg_get_functiondef(func_oid) INTO qry;
  SELECT replace(qry, source_schema, dest_schema) INTO dest_qry;
  EXECUTE dest_qry;

END LOOP;

RETURN; 
```

### Generating a list of functions

We need at least one function to clone, so why not add the function that
this article is about? You <u>could</u> scroll all the way back to the
page, copy and paste it in your psql or pgAdmin or whatever you're using
to follow along… or you could do what the uncool kids are doing and
evaluate the following expression in Emacs.

``` commonlisp
(org-sbe clone_schema_func)
```

Now, we can search for all functions in our current schema

``` sql
SELECT oid, proname, pronamespace
  FROM pg_proc
  WHERE proname = 'clone_schema'
```

We can do the same as our base query by getting the object id of our
current schema…

``` SQL
SELECT oid
      FROM pg_namespace
     WHERE nspname = 'public'
```

and to put that together

``` sql
SELECT oid, proname, pronamespace
  FROM pg_proc
  WHERE pronamespace = (SELECT oid
                        FROM pg_namespace
                        WHERE nspname = 'public')
```

> Wouldn't this be a lot easier when we're inside a function and have
> access to variables? Oh, and we have loops?

### Copying Functions

Now that we have ensured we have data to play with, we now need to:

1.  get all function definitions
2.  replace every reference to source_schema with dest_schema within
    those functions
3.  execute all function definitions as queries.

<!-- -->

1.  Step 1

    Get a function defition from a func_oid

    ``` sql
    SELECT pg_get_functiondef(16675);
    ```

    > This section omitted for brevity.

2.  Step 2

    Use the
    [replace](https://www.postgresql.org/docs/14/functions-string.html)
    function to change the schema name references

    ``` sql
    SELECT replace((SELECT pg_get_functiondef(16675)), 'public', 'backup');
    ```

    > This section omitted for brevity

3.  Step 3

    Now we need to do a little bit of magic and wrap our Execute call in
    an anonymous function to ensure it runs.

    ``` sql
    DO $$
    BEGIN
      EXECUTE replace((
        SELECT
          pg_get_functiondef(16675)), 'public', 'backup');
      END$$
    ```

    I am not sure why the above works and below gives us an error
    talking about how the prepared statement replace does not exist.

    ``` sql
    EXECUTE replace((SELECT pg_get_functiondef(16496)), 'public', 'backup');
    ```

    But ignoring that, then we can validate our work by searching for
    this cloned function in the new schema

    ``` sql
    SELECT oid, proname, pronamespace
      FROM pg_proc
      WHERE pronamespace = (SELECT oid
                            FROM pg_namespace
                            WHERE nspname = 'backup')
    ```

### Playground

``` sql
DO $$
DECLARE
  func_oid oid;
  src_oid oid;
  qry text;
  dest_qry text;
  source_schema text;
  dest_schema text;
BEGIN
  source_schema := 'public';
  dest_schema := 'backup';
  SELECT
    oid INTO src_oid
  FROM
    pg_namespace
  WHERE
    nspname = quote_ident(source_schema);
  FOR func_oid IN
  SELECT
    oid
  FROM
    pg_proc
  WHERE
    pronamespace = src_oid LOOP
      SELECT
        pg_get_functiondef(func_oid) INTO qry;
      SELECT
        replace(qry, source_schema, dest_schema) INTO dest_qry;
      EXECUTE dest_qry;
    END LOOP;
  RETURN;
END
$$;

```

## Fin

And that, in essence, is how you copy one schema into the next. I think
that was pretty simple… you know, once it's been broken down into a
bunch of small readable chunks that you can easily play with.

## Footnotes

[1] Why log_cnt exists is kind of interesting.
<https://stackoverflow.com/a/66458412>

[2] is_called is boolean that modifies what setval returns.
<https://www.postgresql.org/docs/14/functions-sequence.html>
