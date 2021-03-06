/*
This monolithic program is meant to act as a Swift-T wrapper for all of the other pieces of the variant calling
  workflow. If configured correctly, it will be able to easily skip steps of the workflow to accommodate those who
  are jumping in and out of each stage.

Because each module of the main workflow needs to be able to operate independently of the others, every module parses
  the sample names provided in the SAMPLEINFORMATION flag within the runfile and locates the necessary input files it
  needs for its stage. Although this creates extra code, it is the simplest way to ensure that each piece can function
  independently.

This monolithic script uses 'if-else' statements to determine whether or not to run each stage of the workflow.
  However, since Swift-T will try to run everything automatically unless a dependency is detected and we already
  specified that each module will find its input files manually (see note directly above), the Swift-T compiler will
  not automatically wait for each stage to finish before going on to the next one.
To counter this, we wrote the module pieces such that they return the necessary outputs (whether computed then or just
  retrieved from the output of a previous run) upon completion and control the data flow according to those return
  values.

Runfile variables (Determine which stages will be run):
  ALIGN_STAGE
  DEDUP_SORT_STAGE
  CHR_SPLIT_STAGE
  VC_STAGE
  COMBINE_VARIANT_STAGE
  JOINT_GENOTYPING_STAGE

Within each STAGE, it checks whether it is executed. If so, it runs and returns the output needed for the next STAGE.
  Otherwise, it just finds the output that is already produced, and feeds that to the next STAGE.\
*/

import string;
import unix;
import io;
import files;
import assert;
import sys;

import generalfunctions.general;
import Align;
import DedupSort;
import SplitByChr;
import RealignRecalAndVC;
import CombineVariants;
import JointGenotyping;

/*********************************************************************************************************************
 Initial Setup
**********************************************************************************************************************/

printf(strcat("The SWIFT_TMP environment variable is set to: ", getenv("SWIFT_TMP")));

/*************
 Parse runfile
**************/

//read-in the runfile with argument --runfile=<runfile_name>							       
argv_accept("runfile"); // return error if user supplies other flagged inputs					      
string configFilename = argv("runfile");

file configFile = input_file(configFilename);
string configFileData[] = file_lines(configFile);

// Gather variables
string variables[string] = getConfigVariables(configFileData);

/****************
 Find input files
*****************/

// Get input sample list
file sampleInfoFile = input_file(variables["SAMPLEINFORMATION"]);							       
string sampleLines[] = file_lines(sampleInfoFile);

/*****************
 Create directories
******************/

mkdir(variables["OUTPUTDIR"]) =>
mkdir(variables["TMPDIR"]) =>
mkdir(strcat(variables["TMPDIR"], "/timinglogs")) =>			/* Potential bug fix */
mkdir(strcat(variables["TMPDIR"], "/timinglogs/alignlogs")) =>
mkdir(strcat(variables["TMPDIR"], "/timinglogs/dedupsortlogs")) =>
mkdir(strcat(variables["TMPDIR"], "/timinglogs/vclogs")) =>
mkdir(strcat(variables["TMPDIR"], "/timinglogs/combinelogs")) =>
mkdir(strcat(variables["TMPDIR"], "/timinglogs/jointGenologs")) =>
mkdir(strcat(variables["OUTPUTDIR"], "/deliverables/docs")) =>
/**********************
Create the Failures.log
***********************/

// This file is initialized with an empty string, so it can be appended to later on
file failureLog < strcat(variables["OUTPUTDIR"], "/deliverables/docs/Failures.log") > = write("") =>
file timingLog < strcat(variables["OUTPUTDIR"], "/deliverables/docs/Timing.log") > = write("Sample\tChromosome\tApp status\tTime\tStage\n") =>

/*******************************************
 Copy input files for documentation purposes
*******************************************/

// Copy the runfile and sampleInfoFile to the docs directory for documentation purposes
file docRunfile < strcat(variables["OUTPUTDIR"], "/deliverables/docs/", basename_string(configFilename)
			) > = configFile =>

file docSampleInfo < strcat(variables["OUTPUTDIR"], "/deliverables/docs/",
			    basename_string(filename(sampleInfoFile)) 
			   ) > = sampleInfoFile =>

/*********************************************************************************************************************
 Pipeline Stages
**********************************************************************************************************************/

// Align, sort, and dedup
file alignBams[] = alignRun(sampleLines, variables, failureLog)  =>
logging(variables["TMPDIR"], timingLog, "alignlogs");

assert(size(alignBams) != 0,
       "FAILURE: The aligned bam array was empty: none of the samples finished properly"
      );

if (variables["ALIGN_STAGE"] != "E" &&
    variables["ALIGN_STAGE"] != "End" &&
    variables["ALIGN_STAGE"] != "end" 
   ) {
	file dedupSortedBams[] = dedupSortRun(alignBams, variables, failureLog) =>
	logging(variables["TMPDIR"], timingLog, "dedupsortlogs");
	assert(size(dedupSortedBams) != 0, strcat("FAILURE: The dedupped and sorted bam array was empty: ",
						  "none of the samples finished properly")
	);
	
	if (variables["DEDUP_SORT_STAGE"] != "E" &&
	    variables["DEDUP_SORT_STAGE"] != "End" &&
	    variables["DEDUP_SORT_STAGE"] != "end"
	) {

		if (variables["SPLIT"] == "Yes" ||
		    variables["SPLIT"] == "YES" ||
		    variables["SPLIT"] == "yes" ||
		    variables["SPLIT"] == "Y" ||
		    variables["SPLIT"] == "y"
		   ) {	
			// Split aligned files by chromosome
			file splitBams[][] =  splitByChrRun(dedupSortedBams, variables, failureLog);

			if (variables["CHR_SPLIT_STAGE"] != "E" &&
			    variables["CHR_SPLIT_STAGE"] != "End" &&
			    variables["CHR_SPLIT_STAGE"] != "end"
			   ) {

				assert(size(splitBams) != 0, strcat("FAILURE: The split bam out array was empty: ",
								    "none of the samples were split properly"
								   )
				      );
				// Calls variants for the aligned files that are split by chromosome
				file splitVCFs[][] = VCSplitRun(variables, splitBams, failureLog) =>
				logging(variables["TMPDIR"], timingLog, "vclogs"); 

				if (variables["VC_STAGE"] != "E" &&
				    variables["VC_STAGE"] != "End" &&
				    variables["VC_STAGE"] != "end"
				   ) {

					assert(size(splitVCFs) != 0, strcat("FAILURE: The split variants array was empty: ",
								       "none of the split bam files had their varianted called"
								      )
					      );

					// Combine the variants for each sample
					file VCF_list[] = combineVariantsRun(splitVCFs, variables, failureLog) =>
					logging(variables["TMPDIR"], timingLog, "combinelogs"); 

					if (variables["COMBINE_VARIANT_STAGE"] != "E" &&
					    variables["COMBINE_VARIANT_STAGE"] != "End" &&
					    variables["COMBINE_VARIANT_STAGE"] != "end"
					   ) {

						assert(size(VCF_list) != 0, "FAILURE: The VCFs array was empty");

						// Conduct joint genotyping between all samples
						jointGenotypingRun(VCF_list, variables, timingLog); 
					}
				}
			}
		} else {
			// Call variants for the aligned files
			file VCF_list[] = VCNoSplitRun(variables, dedupSortedBams, failureLog) =>
			logging(variables["TMPDIR"], timingLog, "vclogs");

			if (variables["VC_STAGE"] != "E" &&
			    variables["VC_STAGE"] != "End" &&
			    variables["VC_STAGE"] != "end"
			   ) {

				assert(size(VCF_list) != 0, "FAILURE: The VCFs array was empty");

				// Conduct joint genotyping between all samples
				jointGenotypingRun(VCF_list, variables, timingLog); 
			}
		}
	}
}
