#!/home/httpd/musicbrainz/mb_server/cgi-bin/perl -w
# vi: set ts=4 sw=4 :
#____________________________________________________________________________
#
#   MusicBrainz -- the open internet music database
#
#   Copyright (C) 2000 Robert Kaye
#
#   This program is free software; you can redistribute it and/or modify
#   it under the terms of the GNU General Public License as published by
#   the Free Software Foundation; either version 2 of the License, or
#   (at your option) any later version.
#
#   This program is distributed in the hope that it will be useful,
#   but WITHOUT ANY WARRANTY; without even the implied warranty of
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#   GNU General Public License for more details.
#
#   You should have received a copy of the GNU General Public License
#   along with this program; if not, write to the Free Software
#   Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.
#
#   $Id$
#____________________________________________________________________________

use strict;

package MusicBrainz::Server::Moderation::MOD_EDIT_ARTIST;

use ModDefs qw( :modstatus :artistid MODBOT_MODERATOR MOD_MERGE_ARTIST );
use base 'Moderation';

sub Name { "Edit Artist" }
(__PACKAGE__)->RegisterHandler;

sub PreInsert
{
	my ($self, %opts) = @_;

	my $ar = $opts{'artist'} or die;

	die $self->SetError('Editing this artist is not allowed'),
		if $ar->GetId() == VARTIST_ID or $ar->GetId() == DARTIST_ID;

	my $name = $opts{'name'};
	my $sortname = $opts{'sortname'};
	my $type = $opts{'artist_type'};
	my $resolution = $opts{'resolution'};
	my $begindate = $opts{'begindate'};
	my $enddate = $opts{'enddate'};

	my %new;

	# The artist name must be defined, has to be changed and must not
	# clash with an existing artist.
	if ( defined $name )
	{
		MusicBrainz::TrimInPlace($name);
		$new{'ArtistName'} = $name;
	}

	if ( defined $sortname )
	{
		MusicBrainz::TrimInPlace($sortname);

		die $self->SetError('Empty sort name not allowed.')
			unless $sortname =~ m/\S/;

		$new{'SortName'} = $sortname if $sortname ne $ar->GetSortName();
	}

	if ( defined $type )
	{
		die $self->SetError('Artist type invalid')
			unless Artist::IsValidType($type);

		$new{'Type'} = $type if $type != $ar->GetType();
	}

	if ( defined $resolution )
	{
		MusicBrainz::TrimInPlace($resolution);

		$new{'Resolution'} = $resolution
				if $resolution ne $ar->GetResolution;
	}

	if ( defined $begindate )
	{
		my $datestr = MakeDateStr(@$begindate);
		die $self->SetError('Invalid begin date') unless defined $datestr;

		$new{'BeginDate'} = $datestr if $datestr ne $ar->GetBeginDate();
	}

	if ( defined $enddate )
	{
		my $datestr = MakeDateStr(@$enddate);
		die $self->SetError('Invalid end date') unless defined $datestr;

		$new{'EndDate'} = $datestr if $datestr ne $ar->GetEndDate();
	}


	# User made no changes. No need to insert a moderation.
	return $self->SuppressInsert() if keys %new == 0;


	# record previous values if we set their corresponding attributes
	my %prev;

	$prev{'ArtistName'} = $ar->GetName() if exists $new{'ArtistName'};
	$prev{'SortName'} = $ar->GetSortName() if exists $new{'SortName'};
	$prev{'Type'} = $ar->GetType() if exists $new{'Type'};
	$prev{'Resolution'} = $ar->GetResolution() if exists $new{'Resolution'};
	$prev{'BeginDate'} = $ar->GetBeginDate() if exists $new{'BeginDate'};
	$prev{'EndDate'} = $ar->GetEndDate() if exists $new{'EndDate'};

	$self->SetArtist($ar->GetId);
	$self->SetPrev($self->ConvertHashToNew(\%prev));
	$self->SetNew($self->ConvertHashToNew(\%new));
	$self->SetTable("artist");
	$self->SetColumn("name");
	$self->SetRowId($ar->GetId);
}

# Specialized version of MusicBrainz::MakeDBDateStr:
# Returns '' if year, month and day are empty.
sub MakeDateStr
{
	my ($y, $m, $d) = @_;

	return '' if $y eq '' and $m eq '' and $d eq '';

	return MusicBrainz::MakeDBDateStr($y, $m, $d);
}

sub PostLoad
{
	my $self = shift;
	$self->{'new_unpacked'} = $self->ConvertNewToHash($self->GetNew()) or die;
	$self->{'prev_unpacked'} = $self->ConvertNewToHash($self->GetPrev()) or die;
}

sub IsAutoMod
{
	my ($self, $user_is_automod) = @_;

	# This moderation is automodable
	return 1 if $user_is_automod;

	my $new = $self->{'new_unpacked'};
	my $prev = $self->{'prev_unpacked'};

	my $automod = 1;

	# Changing name or sortname is allowed if the change only affects
	# small things like case etc.
	my ($oldname, $newname) = $self->_normalise_strings(
								$prev->{'ArtistName'}, $new->{'ArtistName'});
	my ($oldsortname, $newsortname) = $self->_normalise_strings(
								$prev->{'SortName'}, $new->{'SortName'});

	$automod = 0 if $oldname ne $newname;
	$automod = 0 if $oldsortname ne $newsortname;

	# Changing a resolution string is never automatic.
	$automod = 0 if exists $new->{'Resolution'};

	# Adding a date is automatic if there was no date yet.
	$automod = 0 if exists $prev->{'BeginDate'} and $prev->{'BeginDate'} ne '';
	$automod = 0 if exists $prev->{'EndDate'} and $prev->{'EndDate'} ne '';

	$automod = 0 if exists $prev->{'Type'} and $prev->{'Type'} != 0;

	return $automod;
}

sub CheckPrerequisites
{
	my $self = shift;
	my $new = $self->{'new_unpacked'};
	my $prev = $self->{'prev_unpacked'};

	my $artist_id = $self->GetRowId();

	if ($artist_id == VARTIST_ID or $artist_id == DARTIST_ID)
	{
		$self->InsertNote(MODBOT_MODERATOR, "You can't rename this artist!");
		return STATUS_ERROR;
	}

	# Load the artist by ID
	require Artist;
	my $ar = Artist->new($self->{DBH});
	$ar->SetId($artist_id);
	unless ($ar->LoadFromId)
	{
		$self->InsertNote(MODBOT_MODERATOR, "This artist has been deleted.");
		return STATUS_FAILEDDEP;
	}

	# Check that its name has not changed.
	if ( exists $prev->{ArtistName} and $ar->GetName() ne $prev->{ArtistName} )
	{
		$self->InsertNote(MODBOT_MODERATOR,
									"This artist has already been renamed.");
		return STATUS_FAILEDPREREQ;
	}

	# Save for ApprovedAction
	$self->{_artist} = $ar;

	return undef; # undef means no error
}


sub ApprovedAction
{
	my $self = shift;
	my $new = $self->{'new_unpacked'};

	my $status = $self->CheckPrerequisites();
	return $status if $status;

	my $artist = $self->{_artist};
	$artist->Update($new) or die "Failed to update artist in MOD_EDIT_ARTIST";

	return STATUS_APPLIED;
}

sub DeniedAction
{
  	my $self = shift;
	my $new = $self->{'new_unpacked'};

	if (my $artist = $new->{'ArtistId'})
	{
		require Artist;
		my $ar = Artist->new($self->{DBH});
		$ar->SetId($artist);
		$ar->Remove;
   }
}

1;
# eof MOD_EDIT_ARTIST.pm
