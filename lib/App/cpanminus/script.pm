package App::cpanminus::script;
use strict;
use Config;
use Cwd ();
use File::Basename ();
use File::Path ();
use File::Spec ();
use File::Copy ();
use Getopt::Long ();

use constant WIN32 => $^O eq 'MSWin32';
use constant SUNOS => $^O eq 'solaris';
use constant PLUGIN_API_VERSION => 0.1;

our $VERSION = "0.9935";
$VERSION = eval $VERSION;

my $quote = WIN32 ? q/"/ : q/'/;

sub new {
    my $class = shift;

    bless {
        home => "$ENV{HOME}/.cpanm",
        cmd  => 'install',
        seen => {},
        notest => undef,
        installdeps => undef,
        force => undef,
        sudo => undef,
        make  => undef,
        verbose => undef,
        quiet => undef,
        interactive => undef,
        log => undef,
        mirrors => [],
        perl => $^X,
        argv => [],
        hooks => {},
        plugins => [],
        local_lib => undef,
        self_contained => undef,
        configure_timeout => 60,
        try_lwp => 1,
        uninstall_shadows => 1,
        @_,
    }, $class;
}

sub env {
    my($self, $key) = @_;
    $ENV{"PERL_CPANM_" . $key} || $ENV{"CPANMINUS_" . $key};
}

sub parse_options {
    my $self = shift;

    local @ARGV = @{$self->{argv}};
    push @ARGV, split /\s+/, $self->env('OPT');
    push @ARGV, @_;

    if ($0 ne '-' && !-t STDIN){ # e.g. $ cpanm < author/requires.cpanm
        push @ARGV, $self->load_argv_from_fh(\*STDIN);
    }

    Getopt::Long::Configure("bundling");
    Getopt::Long::GetOptions(
        'f|force!'  => \$self->{force},
        'n|notest!' => \$self->{notest},
        'S|sudo!'   => \$self->{sudo},
        'v|verbose' => sub { $self->{verbose} = $self->{interactive} = 1 },
        'q|quiet'   => \$self->{quiet},
        'h|help'    => sub { $self->{action} = 'show_help' },
        'V|version' => sub { $self->{action} = 'show_version' },
        'perl=s'    => \$self->{perl},
        'l|local-lib=s' => \$self->{local_lib},
        'L|local-lib-contained=s' => sub { $self->{local_lib} = $_[1]; $self->{self_contained} = 1 },
        'recent'    => sub { $self->{action} = 'show_recent' },
        'list-plugins' => sub { $self->{action} = 'list_plugins' },
        'installdeps' => \$self->{installdeps},
        'skip-installed!' => \$self->{skip_installed},
        'interactive!' => \$self->{interactive},
        'i|install' => sub { $self->{cmd} = 'install' },
        'look'      => sub { $self->{cmd} = 'look' },
        'info'      => sub { $self->{cmd} = 'info' },
        'self-upgrade' => sub { $self->{cmd} = 'install'; $self->{skip_installed} = 1; push @ARGV, 'App::cpanminus' },
        'disable-plugins!' => \$self->{disable_plugins},
        'uninst-shadows!'  => \$self->{uninstall_shadows},
        'lwp!'    => \$self->{try_lwp},
    );

    $self->{argv} = \@ARGV;
}

sub check_libs {
    my $self = shift;
    return if $self->{_checked}++;

    $self->bootstrap_local_lib;
    if (@{$self->{bootstrap_deps} || []}) {
        local $self->{force} = 1; # to force install EUMM
        $self->install_deps(Cwd::cwd, 0, @{$self->{bootstrap_deps}});
    }
}

sub doit {
    my $self = shift;

    $self->setup_home;
    $self->load_plugins;
    $self->init_tools;

    if (my $action = $self->{action}) {
        $self->$action() and return;
    }

    $self->show_help(1) unless @{$self->{argv}};

    $self->configure_mirrors;

    for my $module (@{$self->{argv}}) {
        $self->install_module($module, 0);
    }

    $self->run_hooks(finalize => {});
}

sub setup_home {
    my $self = shift;

    $self->{home} = $self->env('HOME') if $self->env('HOME');

    unless (_writable($self->{home})) {
        die "Can't write to cpanm home '$self->{home}': You should fix it with chown/chmod first.\n";
    }

    $self->{base} = "$self->{home}/work/" . time . ".$$";
    $self->{plugin_dir} = "$self->{home}/plugins";
    File::Path::mkpath([ $self->{base}, $self->{plugin_dir} ], 0, 0777);

    my $link = "$self->{home}/latest-build";
    eval { unlink $link; symlink $self->{base}, $link };

    $self->{log} = File::Spec->catfile($self->{home}, "build.log"); # because we use shell redirect

    {
        my $log = $self->{log}; my $base = $self->{base};
        $self->{at_exit} = sub {
            my $self = shift;
            File::Copy::copy($self->{log}, "$self->{base}/build.log");
        };
    }

    open my $out, ">$self->{log}" or die "$self->{log}: $!";
    print $out "cpanm (App::cpanminus) $VERSION on perl $] built for $Config{archname}\n";
    print $out "Work directory is $self->{base}\n";
}

sub register_core_hooks {
    my $self = shift;

    $self->hook('core', search_module => sub {
        my $args = shift;
        my $self   = $args->{app};
        my $module = $args->{module};
        push @{$args->{uris}}, sub {
            $self->chat("Searching $module on cpanmetadb ...\n");
            my $uri  = "http://cpanmetadb.appspot.com/v1.0/package/$module";
            my $yaml = $self->get($uri);
            my $meta = $self->parse_meta_string($yaml);
            if ($meta->{distfile}) {
                return $self->cpan_uri($meta->{distfile});
            }
            $self->diag_fail("Finding $module on cpanmetadb failed.");
            return;
        };
    });

    $self->hook('core', search_module => sub {
        my $args = shift;
        my $self   = $args->{app};
        my $module = $args->{module};
        push @{$args->{uris}}, sub {
            $self->chat("Searching $module on search.cpan.org ...\n");
            my $uri  = "http://search.cpan.org/perldoc?$module";
            my $html = $self->get($uri);
            $html =~ m!<a href="/CPAN/authors/id/(.*?\.(?:tar\.gz|tgz|tar\.bz2|zip))">!
                and return $self->cpan_uri($1);
            $self->diag_fail("Finding $module on search.cpan.org failed.");
            return;
        };
    });

    $self->hook('core', show_recent => sub {
        my $args = shift;
        my $self = $args->{app};

        $self->chat("Fetching recent feed from search.cpan.org ...\n");
        my $feed = $self->get("http://search.cpan.org/uploads.rdf");

        my @dists;
        while ($feed =~ m!<link>http://search\.cpan\.org/~([a-z_\-0-9]+)/(.*?)/</link>!g) {
            my($pause_id, $dist) = (uc $1, $2);
            # FIXME Yes, it doesn't always have to be 'tar.gz'
            push @dists, substr($pause_id, 0, 1) . "/" . substr($pause_id, 0, 2) . "/" . $pause_id . "/$dist.tar.gz";
            last if @dists >= 50;
        }

        return \@dists;
    });
}

sub load_plugins {
    my $self = shift;

    $self->_load_plugins;
    $self->register_core_hooks;

    for my $hook (keys %{$self->{hooks}}) {
        $self->{hooks}->{$hook} = [ sort { $a->[0] <=> $b->[0] } @{$self->{hooks}->{$hook}} ];
    }

    $self->run_hooks(init => {});
}

sub _load_plugins {
    my $self = shift;
    return if $self->{disable_plugins};
    return unless $self->{plugin_dir} && -e $self->{plugin_dir};

    opendir my $dh, $self->{plugin_dir} or return;
    my @plugins;
    while (my $e = readdir $dh) {
        my $f = "$self->{plugin_dir}/$e";
        next unless -f $f && $e =~ /^[A-Za-z0-9_]+$/ && $e ne 'README';
        push @plugins, [ $f, $e ];
    }

    for my $plugin (sort { $a->[1] <=> $b->[1] } @plugins) {
        $self->load_plugin(@$plugin);
    }
}

sub load_plugin {
    my($self, $file, $name) = @_;

    # TODO remove this once plugin API is official
    unless ($self->env('DEV')) {
        $self->chat("! Found plugin $file but PERL_CPANM_DEV is not set. Skipping.\n");
        return;
    }

    $self->chat("Loading plugin $file\n");

    my $plugin = { name => $name, file => $file };
    my @attr   = qw( name description author version synopsis );
    my $dsl    = join "\n", map "sub $_ { \$plugin->{$_} = shift }", @attr;

    (my $package = $file) =~ s/[^a-zA-Z0-9_]/_/g;
    my $code = do { open my $io, "<$file"; local $/; <$io> };

    my $api_version = PLUGIN_API_VERSION;

    my @hooks;
    eval "package App::cpanplus::plugin::$package;\n".
        "use strict;\n$dsl\n" .
        'sub api_version { die "API_COMPAT: $_[0]" if $_[0] < $api_version }' . "\n" .
        "sub hook { push \@hooks, [\@_] };\n$code";

    if ($@ =~ /API_COMPAT: (\S+)/) {
        $self->diag_fail("$plugin->{name} plugin API version is outdated ($1 < $api_version) and needs an update.");
        return;
    } elsif ($@) {
        $self->diag_fail("Loading $name plugin failed. See $self->{log} for details.");
        $self->chat($@);
        return;
    }

    for my $hook (@hooks) {
        $self->hook($plugin->{name}, @$hook);
    }

    push @{$self->{plugins}}, $plugin;
}

sub load_argv_from_fh {
    my($self, $fh) = @_;

    my @argv;
    while(defined(my $line = <$fh>)){
        chomp $line;
        $line =~ s/#.+$//; # comment
        $line =~ s/^\s+//; # trim spaces
        $line =~ s/\s+$//; # trim spaces

        push @argv, split ' ', $line if $line;
    }
    return @argv;
}

sub hook {
    my $cb = pop;
    my($self, $name, $hook, $order) = @_;
    $order = 50 unless defined $order;
    push @{$self->{hooks}->{$hook}}, [ $order, $cb, $name ];
}

sub run_hook {
    my($self, $hook, $args) = @_;
    $self->run_hooks($hook, $args, 1);
}

sub run_hooks {
    my($self, $hook, $args, $first) = @_;
    $args->{app} = $self;
    my $res;
    for my $plugin (@{$self->{hooks}->{$hook} || []}) {
        $res = eval { $plugin->[1]->($args) };
        $self->chat("Running hook '$plugin->[2]' error: $@") if $@;
        last if $res && $first;
    }

    return $res;
}

sub show_version {
    print "cpanm (App::cpanminus) version $VERSION\n";
    return 1;
}

sub show_help {
    my $self = shift;

    if ($_[0]) {
        die <<USAGE;
Usage: cpanm [options] Module [...]

Try `cpanm --help` for more options.
USAGE
    }

    print <<HELP;
Usage: cpanm [options] Module [...]

Options:
  -v,--verbose       Turns on chatty output
  --interactive      Turns on interactive configure (required for Task:: modules)
  -f,--force         force install
  -n,--notest        Do not run unit tests
  -S,--sudo          sudo to run install commands
  --installdeps      Only install dependencies
  --skip-installed   Skip installation if you already have the latest version installed
  --disable-plugins  Disable plugin loading

Commands:
  --self-upgrade     upgrades itself
  --look             Download the tarball and open the directory with your shell
  --info             Displays distribution info on CPAN
  --recent           Show recently updated modules

Examples:

  cpanm CGI                                                 # install CGI
  cpanm MIYAGAWA/Plack-0.99_05.tar.gz                       # full distribution name
  cpanm http://example.org/LDS/CGI.pm-3.20.tar.gz           # install from URL
  cpanm ~/dists/MyCompany-Enterprise-1.00.tar.gz            # install from a local file
  cpanm --interactive Task::Kensho                          # Configure interactively
  cpanm .                                                   # install from local directory
  cpanm --installdeps .                                     # install all the deps for the current directory

HELP

    return 1;
}

sub _writable {
    my $dir = shift;
    my @dir = File::Spec->splitdir($dir);
    while (@dir) {
        $dir = File::Spec->catdir(@dir);
        if (-e $dir) {
            return -w _;
        }
        pop @dir;
    }

    return;
}

sub bootstrap_local_lib {
    my $self = shift;

    # If -l is specified, use that.
    if ($self->{local_lib}) {
        my $lib = $self->{local_lib} =~ /^~/ ? $self->{local_lib} : Cwd::abs_path($self->{local_lib});
        return $self->setup_local_lib($lib);
    }

    # root, locally-installed perl or --sudo: don't care about install_base
    return if $self->{sudo} or (_writable($Config{installsitelib}) and _writable($Config{installsitebin}));

    # local::lib is configured in the shell -- yay
    if ($ENV{PERL_MM_OPT} and ($ENV{MODULEBUILDRC} or $ENV{PERL_MB_OPT})) {
        $self->bootstrap_local_lib_deps;
        return;
    }

    $self->setup_local_lib;

    $self->diag(<<DIAG);
!
! I don't have permission to write to to Perl's shared installation
! directories $Config{installsitelib} and
! $Config{installsitebin}.
!
! Instead, I'll install them in $ENV{HOME}/perl5
!
! If you want to use cpan to install modules for all users:
!   - Run me as a root or with the --sudo option (to install to
!     $Config{installsitelib} and $Config{installsitebin})
!
! If you don't want to install modules for all users, you
! can disable this warning by doing any of the following:
!
!   - Run me with --local-lib option e.g. $0 --local-lib=~/perl5
!   - Set the PERL_CPANM_OPT="--local-lib=~/perl5" environment variable
!     in your shell rc file
!   - Configure local::lib (run "perldoc local::lib" for more info)
!
DIAG
    sleep 2;
}

sub _core_only_inc {
    my($self, $base) = @_;
    require local::lib;
    (
        local::lib->install_base_perl_path($base),
        local::lib->install_base_arch_path($base),
        @Config{qw(privlibexp archlibexp)},
    );
}

sub _dump_inc {
    my($self, $inc) = @_;

    my @inc = map { qq('$_') } (@$inc, '.'); # . for inc/Module/Install.pm

    open my $out, ">$self->{base}/DumpedINC.pm" or die $!;
    local $" = ",";
    print $out "BEGIN { \@INC = (@inc) }\n1;\n";
}

sub _import_local_lib {
    my($self, @args) = @_;
    local $SIG{__WARN__} = sub { }; # catch 'Attempting to write ...'
    local::lib->import(@args);
}

sub setup_local_lib {
    my($self, $base) = @_;

    require local::lib;
    {
        local $0 = 'cpanm'; # so curl/wget | perl works
        $base ||= "~/perl5";
        if ($self->{self_contained}) {
            my @inc = $self->_core_only_inc($base);
            $self->_dump_inc(\@inc);
            $self->{search_inc} = [ @inc ];
        }
        $self->_import_local_lib($base);
    }

    $self->bootstrap_local_lib_deps;
}

sub bootstrap_local_lib_deps {
    my $self = shift;
    push @{$self->{bootstrap_deps}},
        'ExtUtils::MakeMaker' => 6.31,
        'ExtUtils::Install'   => 1.46,
        'Module::Build'       => 0.28; # TODO: 0.36 or later for MYMETA.yml once we do --bootstrap command
}

sub diag_ok {
    my($self, $msg) = @_;
    chomp $msg;
    $msg ||= "OK";
    $self->_diag("$msg\n");
    $self->{in_progress} = 0;
    $self->log("-> $msg\n");
}

sub diag_fail {
    my($self, $msg) = @_;
    chomp $msg;
    if ($self->{in_progress}) {
        $self->_diag("FAIL\n");
        $self->{in_progress} = 0;
    }
    $self->_diag("! $msg\n");
    $self->log("-> FAIL $msg\n");
}

sub diag_progress {
    my($self, $msg) = @_;
    chomp $msg;
    $self->{in_progress} = 1;
    $self->_diag("$msg ");
    $self->log("$msg\n");
}

sub _diag {
    my $self = shift;
    print STDERR @_ if $self->{verbose} or !$self->{quiet};
}

sub diag {
    my($self, $msg) = @_;
    $self->_diag($msg);
    $self->log($msg);
}

sub chat {
    my $self = shift;
    print STDERR @_ if $self->{verbose};
    $self->log(@_);
}

sub log {
    my $self = shift;
    open my $out, ">>$self->{log}";
    print $out @_;
}

sub run {
    my($self, $cmd) = @_;

    if (ref $cmd eq 'ARRAY') {
        my $pid = fork;
        if ($pid) {
            waitpid $pid, 0;
            return !$?;
        } else {
            $self->run_exec($cmd);
        }
    } else {
        unless ($self->{verbose}) {
            $cmd .= " >> " . $self->shell_quote($self->{log}) . " 2>&1";
        }
        !system $cmd;
    }
}

sub run_exec {
    my($self, $cmd) = @_;

    if (ref $cmd eq 'ARRAY') {
        unless ($self->{verbose}) {
            open my $logfh, ">>", $self->{log};
            open STDERR, '>&', $logfh;
            open STDOUT, '>&', $logfh;
            close $logfh;
        }
        exec @$cmd;
    } else {
        unless ($self->{verbose}) {
            $cmd .= " >> " . $self->shell_quote($self->{log}) . " 2>&1";
        }
        exec $cmd;
    }
}

sub run_timeout {
    my($self, $cmd, $timeout) = @_;
    return $self->run($cmd) if WIN32 || $self->{verbose} || !$timeout;

    my $pid = fork;
    if ($pid) {
        eval {
            local $SIG{ALRM} = sub { die "alarm\n" };
            alarm $timeout;
            waitpid $pid, 0;
            alarm 0;
        };
        if ($@ && $@ eq "alarm\n") {
            $self->diag_fail("Timed out (> ${timeout}s). Use --verbose to retry.");
            local $SIG{TERM} = 'IGNORE';
            kill TERM => 0;
            waitpid $pid, 0;
            return;
        }
        return !$?;
    } elsif ($pid == 0) {
        $self->run_exec($cmd);
    } else {
        $self->chat("! fork failed: falling back to system()\n");
        $self->run($cmd);
    }
}

sub configure {
    my($self, $cmd) = @_;

    # trick AutoInstall
    local $ENV{PERL5_CPAN_IS_RUNNING} = $ENV{PERL5_CPANPLUS_IS_RUNNING} = $$;

    # e.g. skip CPAN configuration on local::lib
    local $ENV{PERL5_CPANM_IS_RUNNING} = $$;

    my $use_default = !$self->{interactive};
    local $ENV{PERL_MM_USE_DEFAULT} = $use_default;

    local $self->{verbose} = $self->{verbose} || $self->{interactive};
    $self->run_timeout($cmd, $self->{configure_timeout});
}

sub build {
    my($self, $cmd) = @_;
    $self->run_timeout($cmd, $self->{build_timeout});
}

sub test {
    my($self, $cmd, $force_cb) = @_;
    return 1 if $self->{notest};

    $self->diag( "testing... " );

    local $ENV{AUTOMATED_TESTING} = 1;

    return 1 if $self->run_timeout($cmd,  $self->{test_timeout});
    if ($self->{force}) {
        $force_cb->() if $force_cb;
        return 1;
    }
    return;
}

sub install {
    my($self, $cmd, $uninst_opts) = @_;

    if ($self->{sudo}) {
        unshift @$cmd, "sudo";
    }

    if ($self->{uninstall_shadows}) {
        push @$cmd, @$uninst_opts;
    }

    $self->run($cmd);
}

sub chdir {
    my $self = shift;
    chdir(File::Spec->canonpath($_[0])) or die "$_[0]: $!";
}

sub configure_mirrors {
    my $self = shift;

    my @mirrors;
    $self->run_hook(configure_mirrors => { mirrors => \@mirrors });

    @mirrors = ('http://search.cpan.org/CPAN') unless @mirrors;
    $self->{mirrors} = \@mirrors;
}

sub show_recent {
    my $self = shift;

    my $dists = $self->run_hook(show_recent => {});
    for my $dist (@$dists) {
        print $dist, "\n";
    }

    return 1;
}

sub list_plugins {
    my $self = shift;

    for my $plugin (@{$self->{plugins}}) {
        print "$plugin->{name} - $plugin->{description}\n";
    }

    return 1;
}

sub self_upgrade {
    my $self = shift;
    $self->{argv} = [ 'App::cpanminus' ];
    return; # continue
}

sub install_module {
    my($self, $module, $depth) = @_;

    if ($self->{seen}{$module}++) {
        $self->diag("Already tried $module. Skipping.\n");
        return;
    }
    if ($self->{cmd} !~  /^(?:look|info)$/) {
        $self->check_libs;
    }

    $self->diag("$module: ");

    # FIXME return richer data structure including version number here
    # so --skip-installed option etc. can skip it
    my $dir = $self->fetch_module($module);

    return if $self->{cmd} eq 'info';

    unless ($dir) {
        $self->diag_fail("Couldn't find module or a distribution $module");
        return;
    }

    if ($module ne $dir && $self->{seen}{$dir}++) {
        $self->diag("Already built the distribution $dir. Skipping.\n");
        return;
    }

    $self->chat("Entering $dir\n");
    $self->chdir($self->{base});
    $self->chdir($dir);

    if ($self->{cmd} eq 'look') {
        my $shell = $ENV{SHELL};
        $shell  ||= $ENV{COMSPEC} if WIN32;
        if ($shell) {
            $self->diag("Entering $dir with $shell\n");
            system $shell;
        } else {
            $self->diag_fail("You don't seem to have a SHELL :/");
        }
    } else {
        $self->build_stuff($module, $dir, $depth);
    }
}

sub generator_cb {
    my($self, $ref) = @_;

    $ref = [ $ref ] unless ref $ref eq 'ARRAY';

    my @stack;
    return sub {
        if (@stack) {
            return shift @stack;
        }

        return -1 unless @$ref;
        my $curr = (shift @$ref)->();
        if (ref $curr eq 'ARRAY') {
            @stack = @$curr;
            return shift @stack;
        } else {
            return $curr;
        }
    };
}

sub fetch_module {
    my($self, $module) = @_;

    my($uris, $local_dir) = $self->locate_dist($module);

    return $local_dir if $local_dir;
    return unless $uris;

    my $iter = $self->generator_cb($uris);

    while (1) {
        my $uri = $iter->();
        last if $uri == -1;
        next unless $uri;

        # Yikes this is dirty
        if ($self->{cmd} eq 'info') {
            $uri =~ s!.*authors/id/!!;
            print $uri, "\n";
            return;
        }

        if ($uri =~ m{/perl-5}){
            $self->diag("skip $uri\n");
            next;
        }

        $self->chdir($self->{base});
        if ($self->{verbose}) {
            $self->diag_progress("Fetching $uri");
        } else {
            $self->diag_progress("downloading...");
        }


        my $name = File::Basename::basename $uri;

        my $cancelled;
        my $fetch = sub {
            my $file;
            eval {
                local $SIG{INT} = sub { $cancelled = 1; die "SIGINT\n" };
                $self->mirror($uri, $name);
                $file = $name if -e $name;
            };
            $self->chat("$@") if $@ && $@ ne "SIGINT\n";
            return $file;
        };

        my($try, $file);
        while ($try++ < 3) {
            $file = $fetch->();
            last if $cancelled or $file;
            $self->diag_fail("Download $uri failed. Retrying ... ");
        }

        if ($cancelled) {
            $self->diag_fail("Download cancelled.");
            return;
        }

        unless ($file) {
            $self->diag_fail("Failed to download $uri");
            next;
        }

        $self->diag_ok if ($self->{verbose});

        # TODO add more metadata so plugins can tell how to verify and pass through
        my $args = { file => $file, uri => $uri, fail => 0 };
        $self->run_hooks(verify_archive => $args);

        if ($args->{fail} && !$self->{force}) {
            $self->diag_fail("Verifying the archive $file failed. Skipping. (use --force to install)");
            next;
        }

        my $dir = $self->unpack($file);

        next unless $dir; # unpack failed

        return $dir;
    }
}

sub unpack {
    my($self, $file) = @_;
    $self->chat("Unpacking $file\n");
    my $dir = $file =~ /\.zip/i ? $self->unzip($file) : $self->untar($file);
    unless ($dir) {
        $self->diag_fail("Failed to unpack $file: no directory");
    }
    return $dir;
}

sub locate_dist {
    my($self, $module) = @_;

    if (my $located = $self->run_hook(locate_dist => { module => $module })) {
        return ref $located eq 'ARRAY' ? @$located :
               ref $located eq 'CODE'  ? $located  : sub { $located };
    }

    # URL
    return sub { $module } if $module =~ /^(ftp|https?|file):/;

    # Directory
    return undef, Cwd::abs_path($module) if $module =~ m!^[\./]! && -d $module;

    # File
    return sub { "file://" . Cwd::abs_path($module) } if -f $module;

    # cpan URI
    $module =~ s!^cpan:///distfile/!!;

    # PAUSEID/foo
    $module =~ s!^([A-Z]{3,})/!substr($1, 0, 1)."/".substr($1, 0, 2) ."/" . $1 . "/"!e;

    # CPAN tarball
    return sub { $self->cpan_uri($module) } if $module =~ m!^[A-Z]/[A-Z]{2}/!;

    # Module name -- search.cpan.org
    return $self->search_module($module);
}

sub cpan_uri {
    my($self, $dist) = @_;

    my @mirrors = @{$self->{mirrors}};
    my @urls    = map "$_/authors/id/$dist", @mirrors;

    return wantarray ? @urls : $urls[int(rand($#urls))];
}

sub search_module {
    my($self, $module) = @_;

    my @cbs;
    $self->run_hooks(search_module => { module => $module, uris => \@cbs });

    return \@cbs;
}

sub check_module {
    my($self, $mod, $want_ver) = @_;

    require Module::Metadata;
    my $meta = Module::Metadata->new_from_module($mod, inc => $self->{search_inc})
        or return 0, undef;

    my $version = $meta->version;
    $self->{local_versions}{$mod} = $version;

    if ($self->is_deprecated($meta)){
        return 0, $version;
    } elsif (!$want_ver or $version >= Module::Metadata::Version->new($want_ver)) {
        return 1, $version;
    } else {
        return 0, $version;
    }
}

sub is_deprecated {
    my($self, $meta) = @_;

    my $deprecated = eval {
        require Module::CoreList;
        Module::CoreList::is_deprecated($meta->{module});
    };

    return unless $deprecated;

    require Config;
    for my $dir (qw(archlibexp privlibexp)) {
        my $confdir = $Config{$dir};
        if ($confdir eq substr($meta->filename, 0, length($confdir))) {
            return 1;
        }
    }

    return;
}

sub should_install {
    my($self, $mod, $ver) = @_;

    $self->chat("Checking if you have $mod $ver ... ");
    my($ok, $local) = $self->check_module($mod, $ver);

    if ($ok)       { $self->chat("Yes ($local)\n") }
    elsif ($local) { $self->chat("No ($local < $ver)\n") }
    else           { $self->chat("No\n") }

    return $mod unless $ok;
    return;
}

sub install_deps {
    my($self, $dir, $depth, @deps) = @_;

    my(@install, %seen);
    while (my($mod, $ver) = splice @deps, 0, 2) {
        next if $seen{$mod} or $mod eq 'perl' or $mod eq 'Config';
        if ($self->should_install($mod, $ver)) {
            push @install, $mod;
            $seen{$mod} = 1;
        }
    }

    if (@install) {
        $self->diag("\n ==> Installing dependencies: " . join(", ", @install) . "\n");
    }

    for my $mod (@install) {
        $self->install_module($mod, $depth + 1);
    }

    $self->chdir($self->{base});
    $self->chdir($dir) if $dir;
    return (\@install);
}

sub build_stuff {
    my($self, $module, $dir, $depth) = @_;

    my $args = { module => $module, dir => $dir };
    $self->run_hooks(verify_dist => $args);

    if ($args->{fail} && !$self->{force}) {
        $self->diag_fail("Verifying the module $module failed. Skipping. (use --force to install)");
        return;
    }

    my($meta, @config_deps);
    if (-e 'META.yml') {
        $self->chat("Checking configure dependencies from META.yml\n");
        $meta = $self->parse_meta('META.yml');
        push @config_deps, %{$meta->{configure_requires} || {}};
    }

    # TODO yikes, $module doesn't always have to be CPAN module
    # TODO extract/fetch meta info earlier so you don't need to download tarballs
    if ($depth == 0 && $meta->{version} && $module =~ /^[a-zA-Z0-9_:]+$/) {
        my($ok, $local) = $self->check_module($module, $meta->{version});
        if ($self->{skip_installed} && $ok) {
            $self->diag("$module is up to date. ($local)\n");
            return;
        }
    }

    # get more configure_requires
    $self->run_hooks(pre_configure => { meta => $meta, deps => \@config_deps });
    my $configure_deps = $self->install_deps($dir, $depth, @config_deps);
    diag("$module: ") if (@$configure_deps);


    # Let plugins to take over the build process -- dzil for instance
    my $builder = $self->run_hook(build_dist => { meta => $meta });
    return $builder->() if $builder;

    my $target = $meta->{name} ? "$meta->{name}-$meta->{version}" : $dir;
    $self->diag_progress("configuring...");

    my $configure_state = $self->configure_this($meta->{name});

    $self->diag_ok($configure_state->{configured_ok} ? "OK" : "N/A") if ($self->{verbose});

    my @deps = $self->find_prereqs($meta);

    $self->run_hooks(find_deps => { deps => \@deps, module => $module, meta => $meta });

    my $prereqs = $self->install_deps($dir, $depth, @deps);
    $self->diag("$module: ") if (@$prereqs);

    if ($self->{installdeps} && $depth == 0) {
        $self->diag(" <== Installed dependencies for $module. Finishing.\n");
        return 1;
    }

    my $testdiag = sub {
        $self->diag_fail("Testing $module failed but installing it anyway.");
    };

    my $installed;

    my $progress = sub {
        my ( $target, $module ) = (@_);
        if ( $self->{verbose} ) {
            $self->diag_progress( "building $target for $module" );
        }
        else {
            $self->diag_progress( "building..." );

        }
    };

    if ($configure_state->{use_module_build} && -e 'Build' && -f _) {
        $progress->($target, $module);
        $self->build([ $self->{perl}, "./Build" ]) &&
        $self->test([ $self->{perl}, "./Build", "test" ], $testdiag) &&
        $self->install([ $self->{perl}, "./Build", "install" ], [ "--uninst", 1 ]) &&
        $installed++;
    } elsif ($self->{make} && -e 'Makefile') {
        $progress->($target, $module);
        $self->build([ $self->{make} ]) &&
        $self->test([ $self->{make}, "test" ], $testdiag) &&
        $self->install([ $self->{make}, "install" ], [ "UNINST=1" ]) &&
        $installed++;
    } else {
        my $why;
        my $configure_failed = $configure_state->{configured} && !$configure_state->{configured_ok};
        if ($configure_failed) { $why = "Configure failed on $dir." }
        elsif ($self->{make})  { $why = "The distribution doesn't have a proper Makefile.PL/Build.PL" }
        else                   { $why = "Can't configure the distribution. You probably need to have 'make'." }

        $self->diag_fail("$why See $self->{log} for details.");
        $self->run_hooks(configure_failure => { module => $module, build_dir => $dir, meta => $meta });
        return;
    }

    # TODO calculate this earlier and put it in the stash
    my $distname = $meta->{name} ? "$meta->{name}-$meta->{version}" : $module;

    if ($installed) {
        my $local = $self->{local_versions}{$module};
        my $reinstall = $local && $local eq $meta->{version};

        my $how = $reinstall ? "reinstalled $distname"
                : $local     ? "installed $distname (upgraded from $local)"
                             : "installed $distname" ;
        my $msg = "$module: Successfully $how";
        $self->diag_ok;
        $self->chat("$msg\n");
        $self->run_hooks(install_success => {
            module => $module, build_dir => $dir, meta => $meta,
            local => $local, reinstall => $reinstall, depth => $depth,
            message => $msg, dist => $distname
        });
        return 1;
    } else {
        my $msg = "Building $distname failed";
        $self->diag_fail("Installation of $module failed. See $self->{log} for details.");
        $self->run_hooks(build_failure => {
            module => $module, build_dir => $dir, meta => $meta,
            message => $msg, dist => $distname,
        });
        return;
    }
}

sub configure_this {
    my($self, $name) = @_;

    my @switches;
    @switches = ("-I$self->{base}", "-MDumpedINC") if $self->{self_contained};
    local $ENV{PERL5LIB} = ''                      if $self->{self_contained};

    my $state = {};

    my $try_eumm = sub {
        if (-e 'Makefile.PL') {
            $self->chat("Running Makefile.PL\n");
            local $ENV{X_MYMETA} = 'YAML';

            # NOTE: according to Devel::CheckLib, most XS modules exit
            # with 0 even if header files are missing, to avoid receiving
            # tons of FAIL reports in such cases. So exit code can't be
            # trusted if it went well.
            if ($self->configure([ $self->{perl}, @switches, "Makefile.PL" ])) {
                $state->{configured_ok} = -e 'Makefile';
            }
            $state->{configured}++;
        }
    };

    my $try_mb = sub {
        if (-e 'Build.PL') {
            $self->chat("Running Build.PL\n");
            if ($self->configure([ $self->{perl}, @switches, "Build.PL" ])) {
                $state->{configured_ok} = -e 'Build' && -f _;
            }
            $state->{use_module_build}++;
            $state->{configured}++;
        }
    };

    # Module::Build deps should use MakeMaker because that causes circular deps and fail
    # Otherwise we should prefer Build.PL
    my %should_use_mm = map { $_ => 1 } qw( version ExtUtils-ParseXS ExtUtils-Install ExtUtils-Manifest );

    my @try;
    if ($name && $should_use_mm{$name}) {
        @try = ($try_eumm, $try_mb);
    } else {
        @try = ($try_mb, $try_eumm);
    }

    for my $try (@try) {
        $try->();
        last if $state->{configured_ok};
    }

    return $state;
}

sub safe_eval {
    my($self, $code) = @_;
    eval $code;
}

sub find_prereqs {
    my($self, $meta) = @_;

    my @deps;
    if (-e 'MYMETA.yml') {
        $self->chat("Checking dependencies from MYMETA.yml ...\n");
        my $mymeta = $self->parse_meta('MYMETA.yml');
        @deps = $self->extract_requires($mymeta);
        $meta->{$_} = $mymeta->{$_} for keys %$mymeta; # merge
    } elsif (-e '_build/prereqs') {
        $self->chat("Checking dependencies from _build/prereqs ...\n");
        my $mymeta = do { open my $in, "_build/prereqs"; $self->safe_eval(join "", <$in>) };
        @deps = $self->extract_requires($mymeta);
    }

    if (-e 'Makefile') {
        $self->chat("Finding PREREQ from Makefile ...\n");
        open my $mf, "Makefile";
        while (<$mf>) {
            if (/^\#\s+PREREQ_PM => ({.*?})/) {
                my $prereq = $self->safe_eval("no strict; +$1");
                push @deps, %$prereq if $prereq;
                last;
            }
        }
    }

    # No need to remove, but this gets in the way of signature testing :/
    unlink 'MYMETA.yml';

    return @deps;
}

sub extract_requires {
    my($self, $meta) = @_;

    my @deps;
    push @deps, %{$meta->{requires}} if $meta->{requires};
    push @deps, %{$meta->{build_requires}} if $meta->{build_requires};

    return @deps;
}

sub DESTROY {
    my $self = shift;
    $self->{at_exit}->($self) if $self->{at_exit};
}

# Utils

sub shell_quote {
    my($self, $stuff) = @_;
    $quote . $stuff . $quote;
}

sub which {
    my($self, $name) = @_;
    my $exe_ext = $Config{_exe};
    for my $dir (File::Spec->path) {
        my $fullpath = File::Spec->catfile($dir, $name);
        if (-x $fullpath || -x ($fullpath .= $exe_ext)) {
            if ($fullpath =~ /\s/ && $fullpath !~ /^$quote/) {
                $fullpath = $self->shell_quote($fullpath);
            }
            return $fullpath;
        }
    }
    return;
}

sub get      { $_[0]->{_backends}{get}->(@_) };
sub mirror   { $_[0]->{_backends}{mirror}->(@_) };
sub redirect { $_[0]->{_backends}{redirect}->(@_) };
sub untar    { $_[0]->{_backends}{untar}->(@_) };
sub unzip    { $_[0]->{_backends}{unzip}->(@_) };

sub file_get {
    my($self, $uri) = @_;
    open my $fh, "<$uri" or return;
    join '', <$fh>;
}

sub file_mirror {
    my($self, $uri, $path) = @_;
    File::Copy::copy($uri, $path);
}

sub init_tools {
    my $self = shift;

    return if $self->{initialized}++;

    if ($self->{make} = $self->which($Config{make})) {
        $self->chat("You have make $self->{make}\n");
    }

    # use --no-lwp if they have a broken LWP, to upgrade LWP
    if ($self->{try_lwp} && eval { require LWP::UserAgent; LWP::UserAgent->VERSION(5.802) }) {
        $self->chat("You have LWP $LWP::VERSION\n");
        my $ua = sub {
            LWP::UserAgent->new(
                parse_head => 0,
                env_proxy => 1,
                agent => "cpanminus/$VERSION",
                timeout => 30,
                @_,
            );
        };
        $self->{_backends}{get} = sub {
            my $self = shift;
            my $res = $ua->()->request(HTTP::Request->new(GET => $_[0]));
            return unless $res->is_success;
            return $res->decoded_content;
        };
        $self->{_backends}{mirror} = sub {
            my $self = shift;
            my $res = $ua->()->mirror(@_);
            $res->code;
        };
        $self->{_backends}{redirect} = sub {
            my $self = shift;
            my $res  = $ua->(max_redirect => 1)->simple_request(HTTP::Request->new(GET => $_[0]));
            return $res->header('Location') if $res->is_redirect;
            return;
        };
    } elsif (my $wget = $self->which('wget')) {
        $self->chat("You have $wget\n");
        $self->{_backends}{get} = sub {
            my($self, $uri) = @_;
            return $self->file_get($uri) if $uri =~ s!^file:/+!/!;
            my $q = $self->{verbose} ? '' : '-q';
            open my $fh, "$wget $uri $q -O - |" or die "wget $uri: $!";
            local $/;
            <$fh>;
        };
        $self->{_backends}{mirror} = sub {
            my($self, $uri, $path) = @_;
            return $self->file_mirror($uri, $path) if $uri =~ s!^file:/+!/!;
            my $q = $self->{verbose} ? '' : '-q';
            system "$wget --retry-connrefused $uri $q -O $path";
        };
        $self->{_backends}{redirect} = sub {
            my($self, $uri) = @_;
            my $out = `$wget --max-redirect=0 $uri 2>&1`;
            if ($out =~ /^Location: (\S+)/m) {
                return $1;
            }
            return;
        };
    } elsif (my $curl = $self->which('curl')) {
        $self->chat("You have $curl\n");
        $self->{_backends}{get} = sub {
            my($self, $uri) = @_;
            return $self->file_get($uri) if $uri =~ s!^file:/+!/!;
            my $q = $self->{verbose} ? '' : '-s';
            open my $fh, "$curl -L $q $uri |" or die "curl $uri: $!";
            local $/;
            <$fh>;
        };
        $self->{_backends}{mirror} = sub {
            my($self, $uri, $path) = @_;
            return $self->file_mirror($uri, $path) if $uri =~ s!^file:/+!/!;
            my $q = $self->{verbose} ? '' : '-s';
            system "$curl -L $uri $q -# -o $path";
        };
        $self->{_backends}{redirect} = sub {
            my($self, $uri) = @_;
            my $out = `$curl -I -s $uri 2>&1`;
            if ($out =~ /^Location: (\S+)/m) {
                return $1;
            }
            return;
        };
    } else {
        require HTTP::Lite;
        $self->chat("Falling back to HTTP::Lite $HTTP::Lite::VERSION\n");
        my $http_cb = sub {
            my($uri, $redir, $cb_gen) = @_;

            my $http = HTTP::Lite->new;

            my($data_cb, $done_cb) = $cb_gen ? $cb_gen->() : ();
            my $req = $http->request($uri, $data_cb);
            $done_cb->($req) if $done_cb;

            my $redir_count;
            while ($req == 302 or $req == 301)  {
                last if $redir_count++ > 5;
                my $loc;
                for ($http->headers_array) {
                    /Location: (\S+)/ and $loc = $1, last;
                }
                $loc or last;
                if ($loc =~ m!^/!) {
                    $uri =~ s!^(\w+?://[^/]+)/.*$!$1!;
                    $uri .= $loc;
                } else {
                    $uri = $loc;
                }

                return $uri if $redir;

                my($data_cb, $done_cb) = $cb_gen ? $cb_gen->() : ();
                $req = $http->request($uri, $data_cb);
                $done_cb->($req) if $done_cb;
            }

            return if $redir;
            return ($http, $req);
        };

        $self->{_backends}{get} = sub {
            my($self, $uri) = @_;
            return $self->file_get($uri) if $uri =~ s!^file:/+!/!;
            my($http, $req) = $http_cb->($uri);
            return $http->body;
        };

        $self->{_backends}{mirror} = sub {
            my($self, $uri, $path) = @_;
            return $self->file_mirror($uri, $path) if $uri =~ s!^file:/+!/!;

            my($http, $req) = $http_cb->($uri, undef, sub {
                open my $out, ">$path" or die "$path: $!";
                binmode $out;
                sub { print $out ${$_[1]} }, sub { close $out };
            });

            return $req;
        };

        $self->{_backends}{redirect} = sub {
            my($self, $uri) = @_;
            return $http_cb->($uri, 1);
        };
    }

    my $tar = $self->which('tar');
    my $tar_ver;
    my $maybe_bad_tar = sub { WIN32 || SUNOS || (($tar_ver = `$tar --version 2>/dev/null`) =~ /GNU.*1\.13/i) };

    if ($tar && !$maybe_bad_tar->()) {
        chomp $tar_ver;
        $self->chat("You have $tar: $tar_ver\n");
        $self->{_backends}{untar} = sub {
            my($self, $tarfile) = @_;

            my $xf = "xf" . ($self->{verbose} ? 'v' : '');
            my $ar = $tarfile =~ /bz2$/ ? 'j' : 'z';

            my($root, @others) = `$tar tf$ar $tarfile`
                or return undef;

            chomp $root;
            $root =~ s{^(.+)/[^/]*$}{$1};

            system "$tar $xf$ar $tarfile";
            return $root if -d $root;

            $self->diag_fail("Bad archive: $tarfile");
            return undef;
        }
    } elsif (    $tar
             and my $gzip = $self->which('gzip')
             and my $bzip2 = $self->which('bzip2')) {
        $self->chat("You have $tar, $gzip and $bzip2\n");
        $self->{_backends}{untar} = sub {
            my($self, $tarfile) = @_;

            my $x  = "x" . ($self->{verbose} ? 'v' : '') . "f -";
            my $ar = $tarfile =~ /bz2$/ ? $bzip2 : $gzip;

            my($root, @others) = `$ar -dc $tarfile | $tar tf -`
                or return undef;

            chomp $root;
            $root =~ s{^(.+)/[^/]*$}{$1};

            system "$ar -dc $tarfile | $tar $x";
            return $root if -d $root;

            $self->diag_fail("Bad archive: $tarfile");
            return undef;
        }
    } elsif (eval { require Archive::Tar }) { # uses too much memory!
        $self->chat("Falling back to Archive::Tar $Archive::Tar::VERSION\n");
        $self->{_backends}{untar} = sub {
            my $self = shift;
            my $t = Archive::Tar->new($_[0]);
            my $root = ($t->list_files)[0];
            $t->extract;
            return -d $root ? $root : undef;
        };
    } else {
        $self->{_backends}{untar} = sub {
            die "Failed to extract $_[1] - You need to have tar or Archive::Tar installed.\n";
        };
    }

    if (my $unzip = $self->which('unzip')) {
        $self->chat("You have $unzip\n");
        $self->{_backends}{unzip} = sub {
            my($self, $zipfile) = @_;

            my $opt = $self->{verbose} ? '' : '-q';
            my(undef, $root, @others) = `$unzip -t $zipfile`
                or return undef;

            chomp $root;
            $root =~ s{^\s+testing:\s+(.+?)/\s+OK$}{$1};

            system "$unzip $opt $zipfile";
            return $root if -d $root;

            $self->diag_fail("Bad archive: [$root] $zipfile");
            return undef;
        }
    } else {
        $self->{_backends}{unzip} = sub {
            eval { require Archive::Zip }
                or  die "Failed to extract $_[1] - You need to have unzip or Archive::Zip installed.\n";
            my($self, $file) = @_;
            my $zip = Archive::Zip->new();
            my $status;
            $status = $zip->read($file);
            $self->diag_fail("Read of file[$file] failed")
                if $status != Archive::Zip::AZ_OK();
            my @members = $zip->members();
            my $root;
            for my $member ( @members ) {
                my $af = $member->fileName();
                next if ($af =~ m!^(/|\.\./)!);
                $root = $af unless $root;
                $status = $member->extractToFileNamed( $af );
                $self->diag_fail("Extracting of file[$af] from zipfile[$file failed")
                    if $status != Archive::Zip::AZ_OK();
            }
            return -d $root ? $root : undef;
        };
    }
}

sub parse_meta {
    my($self, $file) = @_;
    return eval { (Parse::CPAN::Meta::LoadFile($file))[0] } || {};
}

sub parse_meta_string {
    my($self, $yaml) = @_;
    return eval { (Parse::CPAN::Meta::Load($yaml))[0] } || {};
}

1;
