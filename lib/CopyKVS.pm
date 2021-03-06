package CopyKVS;

use strict;
use warnings;

our $VERSION = '0.02';

use Log::Log4perl qw(:easy);
Log::Log4perl->easy_init(
    {
        level  => $DEBUG,
        utf8   => 1,
        layout => "%d{ISO8601} [%P]: %m%n"
    }
);

use CopyKVS::Handler::AmazonS3;
use CopyKVS::Handler::GridFS;
use CopyKVS::Handler::PostgresBLOB;

use Parallel::Fork::BossWorkerAsync;
use File::Slurp;
use List::Util qw(max);

# Storage handlers:
# {
#     'connector_name_1' => {
#         $pid => $handler,
#         ...
#     },
#     'connector_name_2' => {
#         $pid => $handler,
#         ...
#     },
#     ...
# }
my %_storage_handlers;

if ( $0 =~ /\.inc\.pl/ )
{
    LOGDIE( "Do not run this script directly." );
}

sub _new_storage_handler($$)
{
    my ( $config, $connector_name ) = @_;

    my $handler = undef;

    my $connector = $config->{ connectors }->{ $connector_name };
    unless ( $connector )
    {
        LOGDIE( "Connector '$connector_name' was not found." );
    }

    my $connector_type = $connector->{ type };
    unless ( $connector_type )
    {
        LOGDIE( "Connector type for connector '$connector_name' is not set." );
    }

    if ( lc( $connector_type ) eq lc( 'AmazonS3' ) )
    {
        if ( defined $connector->{ overwrite } )
        {
            LOGDIE(
                "'overwrite' property is deprecated in Amazon S3 connector; please use the global 'overwrite' property" );
        }

        if ( $connector->{ head_before }->{ put } and $config->{ overwrite } )
        {
            LOGWARN( "Both 'overwrite' and 'head_before_putting' are enabled, disabling 'head_before_putting'" );
            $connector->{ head_before }->{ put } = 0;
        }

        $handler = CopyKVS::Handler::AmazonS3->new(
            access_key_id        => $connector->{ access_key_id },
            secret_access_key    => $connector->{ secret_access_key },
            bucket_name          => $connector->{ bucket_name },
            directory_name       => $connector->{ directory_name } || '',
            timeout              => int( $connector->{ timeout } ) // 60,
            use_ssl              => $connector->{ use_ssl } // 0,
            head_before_putting  => $connector->{ head_before }->{ put } // 0,
            head_before_getting  => $connector->{ head_before }->{ get } // 0,
            head_before_deleting => $connector->{ head_before }->{ delete } // 0,
        );

    }
    elsif ( lc( $connector_type ) eq lc( 'GridFS' ) )
    {

        $handler = CopyKVS::Handler::GridFS->new(
            host => $connector->{ host } || 'localhost',
            port => $connector->{ port } || 27017,
            database => $connector->{ database },
            timeout  => int( $connector->{ timeout } ) || -1
        );

    }
    elsif ( lc( $connector_type ) eq lc( 'PostgresBLOB' ) )
    {

        $handler = CopyKVS::Handler::PostgresBLOB->new(
            host => $connector->{ host } || 'localhost',
            port => $connector->{ port } || 5432,
            username    => $connector->{ username },
            password    => $connector->{ password },
            database    => $connector->{ database },
            schema      => $connector->{ schema } || 'public',
            table       => $connector->{ table },
            id_column   => $connector->{ id_column },
            data_column => $connector->{ data_column },
        );

    }
    else
    {

        LOGDIE( "Unconfigured connector type '$connector_type'." );
    }

    return $handler;
}

sub _storage_handler_for_pid($$$)
{
    my ( $config, $connector_name, $pid ) = @_;

    unless ( exists $_storage_handlers{ $connector_name }{ $pid } )
    {

        my $handler = _new_storage_handler( $config, $connector_name );
        unless ( $handler )
        {
            LOGDIE( "Unable to initialize storage handler '$connector_name' for PID $pid" );
        }

        $_storage_handlers{ $connector_name }{ $pid } = $handler;
    }

    if ( scalar keys %_storage_handlers > 200 )
    {
        LOGDIE( "Too many storage handlers initialized. Strange." );
    }

    return $_storage_handlers{ $connector_name }{ $pid };
}

sub _read_last_copied_file($$)
{
    my ( $config, $connector_name ) = @_;

    my $connector = $config->{ connectors }->{ $connector_name };
    unless ( $connector )
    {
        LOGDIE( "Connector '$connector_name' was not found." );
    }

    my $last_copied_file = $connector->{ last_copied_file };
    unless ( defined $last_copied_file )
    {
        LOGDIE( "Last copied file for connector '$connector_name' is not defined." );
    }

    unless ( -e $last_copied_file )
    {
        return undef;
    }

    my $offset_filename = read_file( $last_copied_file );
    unless ( defined $offset_filename )
    {
        LOGDIE( "Last copied file is undefined (read from '$last_copied_file')" );
    }

    chomp $offset_filename;
    return $offset_filename;
}

sub _write_last_copied_file($$$)
{
    my ( $config, $connector_name, $last_copied_filename ) = @_;

    unless ( defined $last_copied_filename )
    {
        LOGDIE( "Last copied filename (that has to be stored) is not defined." );
    }

    my $connector = $config->{ connectors }->{ $connector_name };
    unless ( $connector )
    {
        LOGDIE( "Connector '$connector_name' was not found." );
    }

    my $last_copied_file = $connector->{ last_copied_file };
    unless ( defined $last_copied_file )
    {
        LOGDIE( "Last copied file for connector '$connector_name' is not defined." );
    }

    write_file( $last_copied_file, $last_copied_filename );
}

sub _copy_file_between_connectors
{
    my ( $job ) = @_;

    my $filename       = $job->{ filename };
    my $config         = $job->{ config };
    my $from_connector = $job->{ from_connector };
    my $to_connector   = $job->{ to_connector };

    my $overwrite = $config->{ overwrite } // 1;

    eval {

        # Get storage handlers for current thread (PID)
        my $from_storage = _storage_handler_for_pid( $config, $from_connector, $$ );
        my $to_storage   = _storage_handler_for_pid( $config, $to_connector,   $$ );

        if ( ( !$overwrite ) and $to_storage->head( $filename ) )
        {
            INFO( "Skipping '$filename' because it already exists" );
        }
        else
        {
            INFO( "Copying '$filename'..." );
            $to_storage->put( $filename, $from_storage->get( $filename ) );
        }

    };

    if ( $@ )
    {
        LOGDIE( "Job error occurred while copying '$filename': $@" );
    }

    return { filename => $filename };
}

sub _global_timeout($$$)
{
    my ( $config, $from_connector_name, $to_connector_name ) = @_;

    my $from_connector = $config->{ connectors }->{ $from_connector_name }
      or LOGDIE( "'From' connector '$from_connector_name' was not found." );

    my $to_connector = $config->{ connectors }->{ $to_connector_name }
      or LOGDIE( "'To' connector '$to_connector_name' was not found." );

    my $from_timeout = $from_connector->{ timeout } || -1;
    my $to_timeout   = $to_connector->{ timeout }   || -1;

    return ( $from_timeout == -1 ? 0 : max( $from_timeout, $to_timeout ) * 3 );
}

sub copy_kvs($$$)
{
    my ( $config, $from_connector_name, $to_connector_name ) = @_;

    unless ( $config->{ connectors }->{ $from_connector_name } )
    {
        LOGDIE( "The connector to copy from '$from_connector_name' is not configured." );
    }
    unless ( $config->{ connectors }->{ $to_connector_name } )
    {
        LOGDIE( "The connector to copy to '$to_connector_name' is not configured." );
    }

    # Create lock file
    if ( -e $config->{ lock_file } )
    {
        LOGDIE( "Lock file '$config->{lock_file}' already exists." );
    }
    write_file( $config->{ lock_file }, "$$" );

    # Read last copied filename
    my $offset_filename = _read_last_copied_file( $config, $from_connector_name );
    if ( defined $offset_filename )
    {
        INFO( "Will resume from '$offset_filename'." );
    }
    else
    {
        INFO( "Will start from beginning." );
    }

    my $worker_threads = $config->{ worker_threads }
      or LOGDIE( "Invalid number of worker threads ('worker_threads')." );
    my $job_chunk_size = $config->{ job_chunk_size }
      or LOGDIE( "Invalid number of jobs to enqueue at once ('job_chunk_size')." );

    # Initialize worker manager
    my $bw = Parallel::Fork::BossWorkerAsync->new(
        work_handler   => \&_copy_file_between_connectors,
        global_timeout => _global_timeout( $config, $from_connector_name, $to_connector_name ),
        worker_count   => $worker_threads,
    );

    # Copy
    my $from_storage = _storage_handler_for_pid( $config, $from_connector_name, $$ );

    my $list_iterator   = $from_storage->list_iterator( $offset_filename );
    my $have_files_left = 1;
    while ( $have_files_left )
    {
        my $filename;

        for ( my $x = 0 ; $x < $job_chunk_size ; ++$x )
        {
            my $f = $list_iterator->next();
            if ( $f )
            {
                # Filename to copy
                $filename = $f;
            }
            else
            {
                # No filenames left to copy, leave $filename at the last filename copied
                # so that _write_last_copied_file() can write that down
                $have_files_left = 0;
                last;
            }
            DEBUG( "Enqueueing filename '$filename'" );
            my $job = {
                filename       => $filename,
                config         => $config,
                from_connector => $from_connector_name,
                to_connector   => $to_connector_name,
            };
            $bw->add_work( $job );
        }

        while ( $bw->pending() )
        {
            my $ref = $bw->get_result();
            if ( $ref->{ ERROR } )
            {
                LOGDIE( "Job error: $ref->{ERROR}" );
            }
            else
            {
                DEBUG( "Copied file '$ref->{filename}'" );
            }
        }

        # Store the last filename from the chunk as the last copied
        if ( $filename )
        {
            _write_last_copied_file( $config, $from_connector_name, $filename );
        }
    }

    $bw->shut_down();

    # Remove lock file
    unlink $config->{ lock_file };

    INFO( "Done." );

    return 1;
}

1;

=head1 NAME

CopyKVS - Copy objects between various key-value stores (MongoDB GridFS, Amazon
S3, PostgreSQL BLOB tables)

=head1 SYNOPSIS

  use CopyKVS;

=head1 DESCRIPTION

Copy objects between various key-value stores (MongoDB GridFS, Amazon S3,
PostgreSQL BLOB tables).

=head2 EXPORT

None by default.

=head1 AUTHOR

Linas Valiukas, E<lt>lvaliukas@cyber.law.harvard.eduE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2013- Linas Valiukas, 2013- Berkman Center for Internet &
Society.

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself, either Perl version 5.18.2 or, at your option,
any later version of Perl 5 you may have available.

=cut
