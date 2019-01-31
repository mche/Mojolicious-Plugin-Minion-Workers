package Mojolicious::Plugin::Minion::Workers;
use Mojo::Base 'Mojolicious::Plugin::Minion';

use Mojo::Util 'monkey_patch';
use Mojo::File 'path';

sub register {
  my ($self, $app, $conf) = @_;

  my $conf_workers = delete $conf->{workers};
  $self->SUPER::register($app, $conf)
    unless $app->renderer->get_helper('minion');

  my $is_manage = !$ARGV[0]
                                  || $ARGV[0] eq 'daemon'
                                  || $ARGV[0] eq 'prefork';
  my $is_prefork = $ENV{HYPNOTOAD_APP}
                                  || ($ARGV[0] && $ARGV[0] eq 'prefork');

  monkey_patch 'Minion',
    'manage_workers' => sub {
      return
        unless $is_manage;

      my $minion = shift;
      my $workers = shift || $conf_workers
        or return;

      if ($is_prefork) {
        $minion->${ \\&prefork }($workers);
      } else {
        $minion->${ \\&subprocess }();
      }
    };

  return $self;
}

# Cases: hypnotoad script/app.pl | perl script/app.pl prefork
sub prefork {
  my ($minion, $workers) = @_;

  my $hypnotoad_pid = check_pid(
    $minion->app->config->{hypnotoad}{pid_file}
    ? path($minion->app->config->{hypnotoad}{pid_file})
    : path($ENV{HYPNOTOAD_APP})->sibling('hypnotoad.pid')
  );
  # Minion job here would be better for graceful restart worker
  # when hot deploy hypnotoad (TODO)
  return
    if $hypnotoad_pid && !$ENV{HYPNOTOAD_STOP};

  kill_all($minion);
  
  return
    if $ENV{HYPNOTOAD_STOP};

  while ($workers--) {
    defined(my $pid = fork())   || die "Can't fork: $!";
    next
      if $pid;

    $0 = "$0 minion worker";
    $ENV{MINION_PID} = $$;
    $minion->app->log->error("Minion worker (pid $$) as prefork was started");
    $minion->worker->run;
    CORE::exit(0);
  }
}

# Cases: morbo script/app.pl | perl script/app.pl daemon
sub subprocess {
  my ($minion) = @_;

  kill_all($minion);

  # subprocess allow run/restart worker later inside app worker
  my $subprocess = Mojo::IOLoop::Subprocess->new();
  $subprocess->run(
    sub {
      my $subprocess = shift;
      $ENV{MINION_PID} = $$;
      $0 = "$0 minion worker";
      $minion->app->log->error("Minion worker (pid $$) as subprocess was started");
      $minion->worker->run;
      return $$;
    },
    sub {1}
  );
  # Dont $subprocess->ioloop->start here!
}

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

# kill all prev workers
sub kill_all {
  my ($minion) = @_;

  kill 'QUIT', $_->{pid}
    and $minion->app->log->error("Minion worker (pid $_->{pid}) was stoped")
    for @{$minion->backend->list_workers()->{workers}};
}

sub task_kill {
  my ($minion, $pid) = @_;
  
}

our $VERSION = '0.09072';# as to Minion/100+0.000<minor>


