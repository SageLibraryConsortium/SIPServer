#
# ILS.pm: Test ILS interface module
#

package ILS;

use warnings;
use strict;
use Sys::Syslog qw(syslog);

use ILS::Item;
use ILS::Patron;
use ILS::Transaction;
use ILS::Transaction::Checkout;
use ILS::Transaction::Checkin;
use ILS::Transaction::FeePayment;
use ILS::Transaction::Hold;

my %supports = (
		'magnetic media' => 1,
		'security inhibit' => 0,
		'offline operation' => 0
		);

sub new {
    my ($class, $institution) = @_;
    my $type = ref($class) || $class;
    my $self = {};

    syslog("DEBUG", "new ILS '%s'", $institution->{id});
    $self->{institution} = $institution;

    return bless $self, $type;
}

sub institution {
    my $self = shift;

    return $self->{institution}->{id};
}

sub supports {
    my ($self, $op) = @_;

    return exists($supports{$op}) ? $supports{$op} : 0;
}

sub check_inst_id {
    my ($self, $id, $whence) = @_;

    if ($id ne $self->{institution}->{id}) {
	syslog("WARNING", "%s: received institution '%s', expected '%s'",
	       $whence, $id, $self->{institution}->{id});
    }
}

sub checkout_ok {
    return 1;
}

sub checkin_ok {
    return 0;
}

sub status_update_ok {
    return 1;
}

sub offline_ok {
    return 0;
}

#
# Checkout(patron_id, item_id, sc_renew):
#    patron_id & item_id are the identifiers send by the terminal
#    sc_renew is the renewal policy configured on the terminal
# returns a status opject that can be queried for the various bits
# of information that the protocol (SIP or NCIP) needs to generate
# the response.
#
sub checkout {
    my ($self, $patron_id, $item_id, $sc_renew) = @_;
    my ($patron, $item, $circ);

   $circ = new ILS::Transaction::Checkout;

    # BEGIN TRANSACTION
    $circ->{patron} = $patron = new ILS::Patron $patron_id;
    $circ->{item} = $item = new ILS::Item $item_id;

    $circ->{ok} = ($circ->{patron} && $circ->{item}) ? 1 : 0;

    if ($circ->{ok}) {
	$item->{patron} = $patron_id;
	$item->{due_date} = time + (14*24*60*60); # two weeks
	push(@{$patron->{items}}, $item_id);
	$circ->{desensitize} = !$item->magnetic;

	syslog("LOG_DEBUG", "ILS::Checkout: patron %s has checked out %s",
	       $patron_id, join(', ', @{$patron->{items}}));
    }

    # END TRANSACTION

    return $circ;
}

sub checkin {
    my ($self, $item_id, $trans_date, $return_date,
	$current_loc, $item_props, $cancel) = @_;
    my ($patron, $item, $circ);

    $circ = new ILS::Transaction::Checkin;
    # BEGIN TRANSACTION
    $circ->{item} = $item = new ILS::Item $item_id;

    # It's ok to check it in if it exists, and if it was checked out
    $circ->{ok} = ($item && $item->{patron}) ? 1 : 0;

    if ($circ->{ok}) {
	$circ->{patron} = $patron = new ILS::Patron $item->{patron};
	delete $item->{patron};
	delete $item->{due_date};
	$patron->{items} = [ grep {$_ ne $item_id} @{$patron->{items}} ];
    }
    # END TRANSACTION

    return $circ;
}

# If the ILS caches patron information, this lets it free
# it up
sub end_patron_session {
    my ($self, $patron_id) = @_;

    # success?, screen_msg, print_line
    return (1, 'Thank you for using Evergreen!', '');
}

sub pay_fee {
    my ($self, $patron_id, $patron_pwd, $fee_amt, $fee_type,
	$pay_type, $fee_id, $trans_id, $currency) = @_;
    my $trans;
    my $patron;

    $trans = new ILS::Transaction::FeePayment;

    $patron = new ILS::Patron $patron_id;

    $trans->{transaction_id} = $trans_id;
    $trans->{patron} = $patron;
    $trans->{ok} = 1;

    return $trans;
}

sub add_hold {
    my ($self, $patron_id, $patron_pwd, $item_id, $title_id,
	$expiry_date, $pickup_location, $hold_type, $fee_ack) = @_;
    my ($patron, $item);
    my $hold;
    my $trans;


    $trans = new ILS::Transaction::Hold;

    # BEGIN TRANSACTION
    $patron = new ILS::Patron $patron_id;
    if (!$patron) {
	$trans->{ok} = 0;
	$trans->{available} = 'N';
	$trans->{screen_msg} = "Invalid Password.";

	return $trans;
    }

    $item = new ILS::Item ($item_id || $title_id);
    if (!$item) {
	$trans->{ok} = 0;
	$trans->{available} = 'N';
	$trans->{screen_msg} = "No such item.";

	# END TRANSACTION (conditionally)
	return $trans;
    } elsif ($item->fee && ($fee_ack ne 'Y')) {
	$trans->{ok} = 0;
	$trans->{available} = 'N';
	$trans->{screen_msg} = "Fee required to place hold.";

	# END TRANSACTION (conditionally)
	return $trans;
    }

    $hold = {
	item_id         => $item->id,
	patron_id       => $patron->id,
	expiration_date => $expiry_date,
	pickup_location => $pickup_location,
	hold_type       => $hold_type,
    };
	
    $trans->{ok} = 1;
    $trans->{patron} = $patron;
    $trans->{item} = $item;
    $trans->{pickup_location} = $pickup_location;

    if ($item->{patron_id}  || scalar @{$item->{hold_queue}}) {
	$trans->{available} = 'N';
    } else {
	$trans->{available} = 'Y';
    }

    push(@{$item->{hold_queue}}, $hold);
    push(@{$patron->{hold_items}}, $hold);


    # END TRANSACTION
    return $trans;
}

sub cancel_hold {
    my ($self, $patron_id, $patron_pwd, $item_id, $title_id) = @_;
    my ($patron, $item, $hold);
    my $trans;

    $trans = new ILS::Transaction::Hold;

    # BEGIN TRANSACTION
    $patron = new ILS::Patron $patron_id;
    if (!$patron) {
	$trans->{ok} = 0;
	$trans->{available} = 'N';
	$trans->{screen_msg} = "Invalid patron barcode.";

	return $trans;
    }

    $item = new ILS::Item ($item_id || $title_id);
    if (!$item) {
	$trans->{ok} = 0;
	$trans->{available} = 'N';
	$trans->{screen_msg} = "No such item.";

	# END TRANSACTION (conditionally)
	return $trans;
    }

    $trans->{ok} = 0;

    # Remove the hold from the patron's record first
    foreach my $i (0 .. scalar @{$patron->{hold_items}}-1) {
	$hold = $patron->{hold_items}[$i];

	if ($hold->{item_id} eq $item_id) {
	    # found it: now delete it
	    splice @{$patron->{hold_items}}, $i, 1;
	    $trans->{ok} = 1;
	    last;
	}
    }

    if (!$trans->{ok}) {
	# We didn't find it on the patron record
	$trans->{available} = 'N';
	$trans->{screen_msg} = "No such hold on patron record.";

	# END TRANSACTION (conditionally)
	return $trans;
    }

    # Now, remove it from the item record.  If it was on the patron
    # record but not on the item record, we'll treat that as success.
    foreach my $i (0 .. scalar @{$item->{hold_queue}}) {
	$hold = $item->{hold_queue}[$i];

	if ($hold->{patron_id} eq $patron->id) {
	    # found it: delete it.
	    splice @{$item->{hold_queue}}, $i, 1;
	    last;
	}
    }

    $trans->{available} = 'Y';
    $trans->{screen_msg} = "Hold Cancelled.";
    $trans->{patron} = $patron;
    $trans->{item} = $item;

    return $trans;
}


# The patron and item id's can't be altered, but the 
# date, location, and type can.
sub alter_hold {
    my ($self, $patron_id, $patron_pwd, $item_id, $title_id,
	$expiry_date, $pickup_location, $hold_type, $fee_ack) = @_;
    my ($patron, $item);
    my $hold;
    my $trans;

    $trans = new ILS::Transaction::Hold;

    $trans->{ok} = 0;
    $trans->{available} = 'N';

    # BEGIN TRANSACTION
    $patron = new ILS::Patron $patron_id;
    if (!$patron) {
	$trans->{screen_msg} = "Invalid patron barcode.";

	return $trans;
    }

    foreach my $i (0 .. scalar @{$patron->{hold_items}}) {
	$hold = $patron->{hold_items}[$i];

	if ($hold->{item_id} eq $item_id) {
	    # Found it.  So fix it.
	    $hold->{expiration_date} = $expiry_date if $expiry_date;
	    $hold->{pickup_location} = $pickup_location if $pickup_location;
	    $hold->{hold_type} = $hold_type if $hold_type;

	    $trans->{ok} = 1;
	    $trans->{screen_msg} = "Hold updated.";
	    $trans->{patron} = $patron;
	    $trans->{item} = new ILS::Item $hold->{item_id};
	    last;
	}
    }

    # The same hold structure is linked into both the patron's
    # list of hold items and into the queue of outstanding holds
    # for the item, so we don't need to search the hold queue for
    # the item, since it's already been updated by the patron code.

    if (!$trans->{ok}) {
	$trans->{screen_msg} = "No such outstanding hold.";
    }

    return $trans;
}

1;
