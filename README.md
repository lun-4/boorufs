# awtfdb

(wip) a "many-compromises" file indexing system.

understand what's up with it here: https://blog.l4.pm/the-system-is-the-solution

## project state

v0.2 is released.

i run master branch, which may be unstable and corrupt your database (like it did to mine,
that was fun)

v0.3 with the goodies of `master` branch will be carved onto stone once Zig reaches v0.11.0
(i'll also attempt to only pin down zig stable versions after that release)

i have been working on this since April 2022, and also been using it on a daily
basis. the base is relatively solid enough, but there are unanswered design
questions, see issues tab.

here are my awtfdb statistics for the past 7 months (May 2023):
 - i have indexed 167405 files.
 - i have created 56190 tags.
 - i have 2425603 file<->tag mappings in the database.
 - my database is 336MB.

there is no specification yet that would enable others to contribute to the
system by writing their own tools on top, but _that is planned_.

this indexing system is very CLI based and there is a szurubooru frontend
for better viewing. see `extra/` for that respective tooling.

as this is v0.x, it is **NOT PRODUCTION READY**. **THERE IS NO WARRANTY PROVIDED
BY ME. I WORK ON THIS PART TIME. BEWARE OF BUGS.**

## how build

- almost everything is cross-platform, save for `awtfdb-watcher`
  - this was not tested as part of the v0.1 effort.
- get [zig](https://github.com/ziglang/zig) (tested with 0.12.0)
- get libmagic and development headers
  - future work to not require this: https://github.com/lun-4/awtfdb/issues/44

```
git clone https://github.com/lun-4/awtfdb
cd awtfdb
zig build
```

## install thing

```
# choose your own prefix thats on $PATH or something
zig build install --prefix ~/.local/ --verbose -Drelease-safe=true
```

## using it

```
# create the awtfdb index file on your home directory
awtfdb-manage create

# add files into the index
# the ainclude tool contains a lot of tag inferrers
# you can see 'ainclude -h' for explanations into such
ainclude --tag meme:what_the_dog_doing ~/my/folder/dog_doing.jpg

# find files with tags
afind meme:what_the_dog_doing

# spawn the rename watcher for libraries that have minimal rename changes
# as the watcher is relatively unstable.
#
# install bpftrace and a recent linux kernel,
# then add this to your init system
awtfdb-watcher /home/user

# list files and their tags with als
als ~/my/folder

# manage tags
atags create my_new_funny_tag
atags search funny
atags delete my_new_funny_tag

# remove files or directories from the index (does not remove from filesystem)
arm -r ~/my/folder
```

## roadmap for the thing

fuck if i know.

## inspiration

- hydrus
- booru software (danbooru etc.)

## (OLD-ISH) design notes

(i leave them there for the funny)

if i could make it a single phrase: awtfdb is an incremental non-destructive tagging system for your life's files full of compromises.

you start it with 'awtfdb path/to/home/directory', it'll create a sqlite file on homedir/awtfdb.db, and run necessary migrations

then, say, you have a folder full of music. you can track them with 'binclude mediadir', but that'd just track them without tags. we know its a media directory, why not infer tags based on content?

'binclude --add-single-tag source:bandcamp --infer-media-tags mediadir/bd-dl'

artist:, title:, album:, and others get inferred from the id3 tags, if those arent provided, inferring from path is done (say, we know title is equal to filename)

you can take a look at the changes binclude will make, it'll always betch-add tags, never remove. if you find that its inferring is wrong for an album, ctrl-c/say no, and redo it ignoring that specific album

'binclude --add-single-tag source:bandcamp --infer-media-tags mediadir/bd-dl --exclude mediadir/bd-dl/album_with_zalgotext'

you can 'badd tag file' to add a single tag to a single file, or to a folder: 'badd -R tag folder'

'bstat path' to see file tags

'bfind <predicate>' to execute search across all files e.g 'bfind format:flac "artist:dj kuroneko"' to return all flacs made by dj kuroneko

### why isnt this a conventional danbooru/hydrus model

the name of a tag isnt unique, tags map to their own tag ids (tag "cores" as ids would be overused vocab from DB world), except, to make this work at universe-scale where i can share my tags with you without conflicting with anything pre-existing

the idea of is shamelessly being copied from the proposal here: https://www.nayuki.io/page/designing-better-file-organization-around-tags-not-hierarchies#complex-indirect-tags

i dont follow that proposal to the letter (storage pools do not apply to me at the moment), but some ideas from it are pretty good to follow

we use hash(random data) as the id, which enables Universal Ids But Theyre Not UUIDs You Cant Just Collide The Tags Lmao (since if you try to change the core_data by even 1 byte, crypto hash gets avalanche effect'd). this enables us to have 'tree (english)', while also having 'Árvore (portuguese)' map to the same id

ofc someone can create a different tag core for the idea of a tree, but thats out of scope. its better than hydrus's PTR because of the fact you can add different human representations to the same tag core, breaking your depedency on english, while also enabling metadata to be added to a tag core, so if i wanted to add the wikipedia link for a tree, i can do that

### some implementation details

now that i have a bit of spec like the db, what happens for implementation?

i want to have something that isnt monolithic, there is no http api of the sorts to manage the database, you just open it, and sqlite will take care of concurrent writers (file based locking)

you just use libawtfdb (name tbd) and itll provide you the high level api such as "execute this query"

there needs to be at least the watcher daemon, but what about secondary functionality? say, i want a program to ensure the hashes are fine for the files, but do it in an ultra slow way, generating reports or even calling notify-send when it finds a discrepancy in hashes

that is a feature way out of scope for the "watcher daemon that only checks up for new renames in the entire filesystem. also thw watcher requires root", adding more things to that piece of code leads to opening my surface area for catastrophic failure. the system should handle all of those processes reading and writing to the database file

#### the db is an IPC platform for all tools

this does infer that the database needs to have more than the tagging data

but a way to become an IPC format between all awtfdb utilities

maybe a janitor process is ensuring all files exist and you want to see the progress bar and plan accordingly, while also ensuring there isn't two of them having to clash with each other's work

ipc and job system

#### one singular tool that does db administration

one tool will have to be database management though

the database migrations will have to go to A Tool Somewhere

maybe awtfdb-manage

create db, run some statistics, show migration warnings, etc

the watcher stays as is, just a watcher for file renames

#### job system

the purpose of a job system in awtfdb

- schedule periodic awtfdb jobs (every week there should be a checkup of
  all paths and their hashes, for example. that job would be a "janitor")
- get job status and _historical_ reports
  - understand failure rate of jobs, if a job fails too much, alerts should
    be dispatched to the user via `notify-send`
  - if the example "janitor" job found a discrepancy between file and hash,
    should it email, fix it automatically, notify-send, or leave a track
    record? that should be configurable by the user.

the implementation proposal for this is as follows:

- job watcher daemon
- `job_configs` table has:
  - id of job
  - configuration of job (json string with well-defined schema in tool?)
  - enabled flag (removing jobs is always a soft delete)
  - executable path of tool
    - the watcher does not run jobs itself, just delegates and supervises
      execution of other executables that actually run what theyre supposed to
- `job_runs` table with historical evidence

technically possible to leave some functionality of the daemon to the
system's initd (systemd, runit+snooze, cron), but i think i might tire myself
out from having to autogenerate service units and connect it all together
and HOPE for a LIGHT FROM GOD that it's going to work as intended. god fuck
linux
