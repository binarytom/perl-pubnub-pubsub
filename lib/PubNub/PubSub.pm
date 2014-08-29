package PubNub::PubSub;

use strict;
use 5.008_005;
our $VERSION = '0.01';

use Carp;
use Mojo::IOLoop;
use Socket qw/$CRLF/;
use Mojo::JSON qw/decode_json/;

sub new {
    my $class = shift;
    my %args  = @_ % 2 ? %{$_[0]} : @_;

    $args{pub_key} or croak "pub_key is required.";
    $args{sub_key} or croak "sub_key is required.";


    $args{host} ||= 'pubsub.pubnub.com';
    $args{port} ||= 80;
    $args{timeout} ||= 60;
    $args{subscribe_timeout} ||= 3600; # 1 hours

    return bless \%args, $class;
}

sub publish {
    my $self = shift;
    my %params = @_ % 2 ? %{$_[0]} : @_;

    my @msg = @{ $params{messages} };
    my $channel = $params{channel} || $self->{channel};
    $channel or croak "channel is required.";

    my $callback = $params{callback} || sub {}; # could be just dummy callback

    # build request
    my @lines;
    foreach my $msg (@msg) {
        push @lines, "GET /publish/" . $self->{pub_key} . '/' . $self->{sub_key} . '/0/' . $channel . '/0/"' . $msg . '" HTTP/1.1';
        push @lines, 'Host: pubsub.pubnub.com';
        push @lines, ''; # for \r\n
    }
    my $r = join("\r\n", @lines) . "\r\n";

    my $id; $id = Mojo::IOLoop->client({
        address => $self->{host},
        port => $self->{port}
    } => sub {
        my ($loop, $err, $stream) = @_;

        $stream->on(read => sub {
            my ($stream, $bytes) = @_;

            ## parse bytes
            $callback->($bytes, shift @msg);

            Mojo::IOLoop->remove($id) unless @msg;
        });

        # Write request
        $stream->write($r);
    });

    Mojo::IOLoop->start unless Mojo::IOLoop->is_running;
}

sub subscribe {
    my $self = shift;
    my %params = @_ % 2 ? %{$_[0]} : @_;

    my $channel = $params{channel} || $self->{channel};
    $channel or croak "channel is required.";

    my $callback = $params{callback} or croak "callback is required.";
    my $timetoken = $params{timetoken} || '0';

    sub __r {
        my ($timetoken) = @_;

        return join("\r\n",
            'GET /subscribe/' . $self->{'sub_key'} . '/' . $channel . '/0/' . $timetoken . ' HTTP/1.1',
            'Host: pubsub.pubnub.com',
            ''
        ) . "\r\n";
    }

    my $delay = Mojo::IOLoop->delay;
    my $end   = $delay->begin;
    my $handle = undef;
    Mojo::IOLoop->client({
        address => $self->{host},
        port => $self->{port},
        timeout => $self->{subscribe_timeout}
    } => sub {
        my ($loop, $err, $stream) = @_;
        $handle = $stream->steal_handle;
        $end->();
    });
    $delay->wait;

    # turn into stream
    my $stream = Mojo::IOLoop::Stream->new($handle)->timeout($self->{subscribe_timeout});
    my $id = Mojo::IOLoop->stream($stream);

    $stream->on(read => sub {
        my ($stream, $bytes) = @_;

        my %data = $self->parse_response($bytes);
        if ($data{json}) {
            $timetoken = $data{json}->[1];
        }

        ## parse bytes
        my $rtn = $callback->($data{json}->[0], \%data);
        unless ($rtn) {
            return Mojo::IOLoop->stop; # stop it
        }

        $stream->write(__r($timetoken)); # never end loop
    });

    # Write request
    $stream->write(__r($timetoken));

    Mojo::IOLoop->start unless Mojo::IOLoop->is_running;
}

sub parse_response {
    my ($self, $resp) = @_;

    my $neck_pos = index($resp, "${CRLF}${CRLF}");
    my $body = substr($resp, $neck_pos+4);
    my $head = substr($resp, 0, $neck_pos);

    my $proto = substr($head, 0, 8);
    my $status_code = substr($head, 9, 3);
    substr($head, 0, index($head, $CRLF) + 2, ""); # 2 = length($CRLF)

    my $header;
    for (split /${CRLF}/o, $head) {
        my ($key, $value) = split /: /, $_, 2;
        $header->{$key} = $value;
    }

    my %data = (
        proto => $proto,
        code  => $status_code,
        header => $header,
        body   => $body,
    );
    if ($data{header}->{'Content-Type'} =~ 'javascript') {
        $data{json} = decode_json($body);
    }

    return wantarray ? %data : \%data;
}

1;
__END__

=encoding utf-8

=head1 NAME

PubNub::PubSub - Perl library for rapid publishing of messages on PubNub.com

=head1 SYNOPSIS

    use PubNub::PubSub;

    my $pubnub = PubNub::PubSub->new(
        pub_key => 'demo',
        sub_key => 'demo',
    );

    # publish
    $pubnub->publish({
        messages => ['message1', 'message2'],
        channel => 'some_unique_channel_perhaps',
        callback => sub {
            my ($res, $req) = @_;

            # ...
        }
    });

    # subscribe
    $pubnub->subscribe({
        channel => 'sandbox',
        callback => sub {
            my ($msgs, $data) = @_;
            foreach my $msg (@$msgs) {
                print "# Got message: $msg\n";
            }
            return 1; # 1 to continue, 0 to stop
        }
    });


=head1 DESCRIPTION

PubNub::PubSub is Perl library for rapid publishing of messages on PubNub.com based on M<Mojo::IOLoop>

=head1 METHOD

=head2 new

=over 4

=item * pub_key

Publish Key, required.

=item * sub_key

Subscribe Key, required.

=item * subscribe_timeout

subscribe stream timeout. default is 1 hour = 3600

=back

=head2 subscribe

subscribe channel to listen for the messages.

    $pubnub->subscribe({
        channel => 'sandbox',
        callback => sub {
            my ($msgs, $data) = @_;
            foreach my $msg (@$msgs) {
                print "# Got message: $msg\n";
            }
            return 1; # 1 to continue, 0 to stop
        }
    });

return 0 to stop

=head2 publish

publish messages to channel

    $pubnub->publish({
        messages => ['message1', 'message2'],
        channel => 'some_unique_channel_perhaps',
        callback => sub {
            my ($res) = @_;

            # ...
        }
    });

all B<messages> will be sent in one socket request. B<callback> could be dummy since there is no special order for that.

=head1 AUTHOR

Binary.com E<lt>fayland@gmail.comE<gt>

=head1 COPYRIGHT

Copyright 2014- Binary.com

=head1 LICENSE

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 SEE ALSO

=cut
