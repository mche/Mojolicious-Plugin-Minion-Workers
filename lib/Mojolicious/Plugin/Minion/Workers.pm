package Mojolicious::Plugin::Minion::Workers;
use Mojo::Base 'Mojolicious::Plugin::Minion';

our $VERSION = '0.9095';# as to Minion version/10+<child minor>

has minion => undef, weak=>1;
has qw(conf);

sub register {
  my ($self, $app, $conf) = @_;

  my $workers = delete $conf->{workers};
  my $manage = delete $conf->{manage};
  my $tasks = delete $conf->{tasks} || {};
  
  my $helper = $app->renderer->get_helper('minion');
  
  my @backend = keys %$conf;
  require Carp;
    and Carp::croak("Too many config args for Mojolicious::Plugin::Minion")
    if @backend > 1 && !$helper;

  $conf->{ $backend[0] } = $conf->{ $backend[0] }->($app)
    if $backend[0] && ref($conf->{ $backend[0] }) eq 'CODE';

  $self->SUPER::register($app, $conf)
    unless !$backend[0] || $helper;

  $self->minion($app->minion);
  $self->conf({
    %$conf,
    workers => $workers,
    is_manage => !$ARGV[0]
                    || $ARGV[0] eq 'daemon'
                    || $ARGV[0] eq 'prefork',
    is_prefork => $ENV{HYPNOTOAD_APP}
                    || ($ARGV[0] && $ARGV[0] eq 'prefork'),
  });

  $app->minion->attr('workers'=> sub { $self }, weak=>1);
  
  while (my ($name, $sub) = each %$tasks) {
    $app->log->debug(sprintf("Applied Minion task [%s] in [%s] from config", $name, $app->minion->add_task($name => $sub)));
  }
  
  $self->manage()
    and $self->conf->{is_manage} = 0
    if $manage;

  return $self;
}

sub manage {
  my ($self, $workers) = @_;
  my $conf = $self->conf;
  return
    unless $conf->{is_manage};

  $workers ||= $conf->{workers}
    or return;

  my $minion = $self->minion;

  if ($conf->{is_prefork}) {
    $self->prefork;
  } else {
    $self->subprocess;
  }
  return $self;
}

# Cases: hypnotoad script/app.pl | perl script/app.pl prefork
sub prefork {
  my ($self) = @_;
  
  # case hot deploy and kill -USR2
  return
    #~ if $hypnotoad_pid && !$ENV{HYPNOTOAD_STOP};
    if $ENV{HYPNOTOAD_PID} && !$ENV{HYPNOTOAD_STOP};

  $self->kill_workers;
  
  return if $ENV{HYPNOTOAD_STOP};

  my $workers = $self->conf->{workers};
  while ($workers--) {
    defined(my $pid = fork())
      || die "Can't fork: $!";
    next  if $pid;
    detach();
    $self->worker_run;
    CORE::exit(0);
  }
}

# Cases: morbo script/app.pl | perl script/app.pl daemon
sub subprocess {
  my ($self) = @_;

  $self->kill_workers;

  # subprocess allow run/restart worker later inside app worker
  my $subprocess = Mojo::IOLoop::Subprocess->new();
  $subprocess->run(
    sub {
      my $subprocess = shift;
      $self->worker_run;
      return $$;
    },
    sub {1}
  );
  # Dont $subprocess->ioloop->start here!
}

sub worker_run {
  my ($self) = @_;
  my $minion = $self->minion;
  $ENV{MINION_PID} = $$;
  $0 = "$0 minion worker";
  $minion->app->log->info("Minion worker (pid $$) was starting");
  $minion->worker->run;
}



sub kill_workers {
  my ($self, $workers) = @_;
  my $minion = $self->minion;
  $workers ||= $minion->backend->list_workers(0,1000)->{workers};

  kill 'QUIT', $_->{pid}
    and $minion->app->log->info("Minion worker (pid $_->{pid}) was stopped")
    for @$workers;
}

 sub detach {
  #~ chdir("/")                  || die "can't chdir to /: $!";
  #~ defined(my $pid = fork())   || die "can't fork: $!";
  #~ return 0
    #~ if $pid; # parent
  
  #~ require POSIX;
  #~ (POSIX::setsid() != -1)               || die "Can't start a new session: $!";
  open(STDIN,  "< /dev/null")    || die "Can't read /dev/null: $!";
  open(STDOUT, "> /dev/null") || die "Can't write to /dev/null: $!";
  open(STDERR, ">&STDOUT")  || die "Can't dup stdout: $!";

   #~ return $$;
 }

1;

__END__

use Mojo::File 'path';

# check process
sub check_pid {
  my ($pid_path) = @_;
  return undef unless -r $pid_path;
  my $pid = $pid_path->slurp;
  chomp $pid;
  # Running
  return $pid if $pid && kill 0, $pid;
  # Not running
  return undef;
}

  # case hot deploy
  #~ my $hypnotoad_pid_file = $minion->app->config->{hypnotoad}{pid_file};
  #~ my $hypnotoad_pid = check_pid(
    #~ ($hypnotoad_pid_file && path($hypnotoad_pid_file))
    #~ || path($ENV{HYPNOTOAD_APP})->sibling('hypnotoad.pid')
  #~ );
  # Minion job here would be better for graceful restart worker
  # when hot deploy hypnotoad (TODO)

#~ # all workers
sub list_workers {
  my ($minion) = @_;
  $minion->backend->pg->db->query(q{
    select *,
      extract(epoch from now()-started) as "time_work",
      count(*) over() as total
    from minion_workers
  })->expand->hashes->to_array;
}

sub killer_task {
  my ($job, $worker, $log) = @_;
  return
    unless $worker->{pid} eq $ENV{MINION_PID};
  $log && $log->info("Minion worker (pid $worker->{pid}) was stoped");
  kill 'QUIT', $worker->{pid};
  $job->finish($worker->{pid});
}