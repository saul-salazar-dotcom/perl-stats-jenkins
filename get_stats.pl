#!/usr/bin/env perl
use Data::Dumper;
use strict;
use warnings;
use 5.010;
use JSON -support_by_pp;
use FindBin;
use POSIX qw(strftime);
use URI;

# for curl
my $who      = 'jenkins_username:' . $ENV{'jenkins_password'};
my $top_url  = 'https://jenkins.tools.YOURCOMPANY.com/';
my $api_path = '/api/json';
my $options  = "--insecure --silent -u $who -b cookie.txt -c cookie.txt";
my $json     = JSON->new->pretty;

# removes some weird characters like SOH
# read more: https://donsnotes.com/tech/charsets/ascii.html
sub sanitize {
    my ($string) = @_;
    $string =~ s/\x01/%01/g;
    return $string;
}

# same as sanitize but for URL special characters
sub encodeURL {
    my ($result) = @_;
    $result = URI->new($result)->as_string;
    $result =~ s/!/%21/g;
    $result =~ s/"/%22/g;
    $result =~ s/#/%23/g;
    $result =~ s/\$/%24/g;
    $result =~ s/&/%26/g;
    $result =~ s/'/%27/g;
    $result =~ s/\(/%28/g;
    $result =~ s/\)/%29/g;
    $result =~ s/\*/%2A/g;
    $result =~ s/\+/%2B/g;
    $result =~ s/\,/%2C/g;
    # $result =~ s/ /%20/g;
    return $result;
}

# makes a curl http call and returns the response as json
sub httpJsonCall {
    my ($url) = @_;
    $url = encodeURL($url);
    my $response      = sanitize(`curl $options "$url" 2>/dev/null`);
    my $responseJson  = $json->decode($response);
    return $responseJson;
}

# prints hours or minutes as a string instead of milliseconds as a number
sub beautifyMilliseconds {
    my ($milliseconds) = @_;
    my $minutes  = ($milliseconds/(1000*60));
    my $hours    = ($milliseconds/(1000*60*60));
    my $result   = "";

    if ($minutes >= 60) {
        $result = sprintf("%.2f", $hours);
        $result = $result . " hours";
    } else {
        $result = sprintf("%.2f", $minutes);
        $result = $result . " minutes";
    }

    return $result;
}

# Turn off output buffering
$|=1;

# read project keys from file
my $file = "$FindBin::Bin/instances.txt";
open(my $fhi, '<:encoding(UTF-8)', $file)
  or die "Could not open file '$file' $!";

my %name_hash;
while (my $key = <$fhi>) {
    chomp $key;
    my ($p,$n) = split ("::",$key);
    $name_hash{$p}{DESC} = $n;
}
close($fhi);

die "Error: secret not defined in the Environment Variable \'m\'\nTo fix, run:\nsource ~/.bash_profile\n" if (! $ENV{'jenkins_user_password'});

# print CSV header
print "Project Key,Server Status,Version,Projects Available,In use?,Last Build Result,Last Build Date,Total Builds,Successful Builds,Failed Builds,Folder Jobs,Freestyle Jobs,Pipeline Jobs,Multibranch Jobs,Maven Jobs,MultiConfig Jobs,Build Duration,Project Description\n";

# let's loop through all project keys and get the status
foreach my $key(sort keys %name_hash) {
    chomp $key;

    # project api url
    my $url  = encodeURL($top_url . $key . $api_path);
    # project pretty name
    my $desc = $name_hash{$key}{'DESC'};

    # init variables for last build
    my $lastBuildDate = 'NA';
    my $lastBuildResult = 'NA';

    # init variables to count the job types
    my $counterFreestyle   = 0;
    my $counterWorkflow    = 0;
    my $counterMultibranch = 0;
    my $counterMaven       = 0;
    my $counterMultiConfig = 0;
    my $counterFolder      = 0;

    # init variables to count the builds (total, duration and successful vs failed)
    my $successfulBuilds = 0;
    my $failedBuilds     = 0;
    my $totalBuilds      = 0;
    my $buildsDuration   = 0;

    # let's get the server status first
    # -I fetch the headers only
    # -w displays a variable from the response
    my $is_up = `curl $options -I -w "%{http_code}" --output '/dev/null' "$url"`;
    my $serverIsDown = $is_up ne '200';
    if ($serverIsDown) {
        print "$key,DOWN,NA,NA,NA,NA,NA,NA,NA,NA,NA,NA,NA,NA,NA,NA,NA,$desc\n";
        next;
    }

    # get version number from header
    my $versionString   = `curl $options -I "$url" | grep -Fi "X-Jenkins:" | tr --delete '\n'`;
    my ($name,$version) = split (": ",$versionString);
    # remove blanklines from string
    $version =~ s/\015?\012?$//;

    # get all jobs
    my $response      = `curl $options "$url" 2>/dev/null`;
    my $responseJson  = $json->decode($response);
    my $projects      = $responseJson->{jobs};
    my $projectsTotal = scalar @$projects;

    # did not find any projects on this server
    if ($projectsTotal <= 0) {
        print "${key},UP,$version,$projectsTotal,NO,NA,NA,NA,NA,NA,NA,NA,NA,NA,NA,NA,NA,$desc\n";
	    next;
    }

    foreach my $project (@{$projects}) {
        $url              = $project->{url} . $api_path;
        my $projectJson   = httpJsonCall($url);
        my $isFolder      = $projectJson->{_class} eq 'com.cloudbees.hudson.plugins.folder.Folder';
        my $isMultiBranch = $projectJson->{_class} eq 'org.jenkinsci.plugins.workflow.multibranch.WorkflowMultiBranchProject';
        my $isMBDefaults  = $projectJson->{_class} eq 'org.jenkinsci.plugins.pipeline.multibranch.defaults.PipelineMultiBranchDefaultsProject';
        my $lastBuildLink = $projectJson->{lastBuild}->{url} || 'NA';
        my $noBuildsFound = $lastBuildLink eq 'NA';

        # metric: job types per instance
        my $type = $project->{_class};
        if ($type eq 'hudson.model.FreeStyleProject') {
            $counterFreestyle++;
        } elsif ($type eq 'org.jenkinsci.plugins.workflow.job.WorkflowJob') {
            $counterWorkflow++;
        } elsif ($type eq 'org.jenkinsci.plugins.workflow.multibranch.WorkflowMultiBranchProject' || $type eq 'org.jenkinsci.plugins.pipeline.multibranch.defaults.PipelineMultiBranchDefaultsProject') {
            $counterMultibranch++;
        } elsif ($type eq 'hudson.maven.MavenModuleSet') {
            $counterMaven++;
        } elsif ($type eq 'hudson.matrix.MatrixProject') {
            $counterMultiConfig++;
        } elsif ($type eq 'com.cloudbees.hudson.plugins.folder.Folder') {
            $counterFolder++;
        }

        # this project doesnt have builds so lets skip it
        if ($noBuildsFound) {
            next;
        }

        # metric: last build (result & date)
        if ($lastBuildDate eq 'NA' || $lastBuildResult eq 'NA') {
            $url = $lastBuildLink . $api_path;
            my $lastBuildJson = httpJsonCall($url);
            # Jenkins uses milliseconds for the unit, and not seconds.
            # So you need to knock off the last few zeros which can be easily done by dividing by 1000.
            my $timestamp = int($lastBuildJson->{timestamp} / 1000);
            $lastBuildDate = strftime("%Y-%m-%d %H:%M:%S",gmtime($timestamp)) || 'NA';
            $lastBuildResult = $lastBuildJson->{result} || 'NA';
        }

        # if this project is a folder or multibranch we will need to dig deeper
        if ($isFolder || $isMultiBranch || $isMBDefaults) {
            my $jobs = $projectJson->{jobs};

            foreach my $job (@{$jobs}) {
                $url                 = $job->{url} . $api_path;
                my $jobJson          = httpJsonCall($url);
                my $jobLastBuildLink = $jobJson->{lastBuild}->{url} || 'NA';
                $noBuildsFound       = $jobLastBuildLink eq 'NA';

                if ($noBuildsFound) {
                    next;
                } else {
                    my $builds = $jobJson->{builds};
                    foreach my $build (@{$builds}) {
                        $url = $build->{url} . $api_path;
                        my $buildJson = httpJsonCall($url);
                        my $result = $buildJson->{result};
                        $buildsDuration += $buildJson->{duration};
                        $totalBuilds++;

                        if ($result eq 'SUCCESS' || $result eq 'STABLE') {
                            $successfulBuilds++;
                        } else {
                            $failedBuilds++;
                        }
                    }
                }
            }
        # but if this project is not a folder or multibranch then we can get the builds directly
        } else {
            my $builds = $projectJson->{builds};
            foreach my $build (@{$builds}) {
                $url = $build->{url} . $api_path;
                my $buildJson = httpJsonCall($url);
                my $result = $buildJson->{result};
                $buildsDuration += $buildJson->{duration};
                $totalBuilds++;

                if ($result eq 'SUCCESS' || $result eq 'STABLE') {
                    $successfulBuilds++;
                } else {
                    $failedBuilds++;
                }
            }
        }

        # iterate next job/project
        next;
    }

    $buildsDuration = beautifyMilliseconds($buildsDuration);
    print "$key,UP,$version,$projectsTotal,YES,$lastBuildResult,$lastBuildDate,$totalBuilds,$successfulBuilds,$failedBuilds,$counterFolder,$counterFreestyle,$counterWorkflow,$counterMultibranch,$counterMaven,$counterMultiConfig,$buildsDuration,$desc\n";
}

exit 0;
