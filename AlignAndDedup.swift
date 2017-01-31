/**********************************************************
 Summary
***********************************************************
Input:
	- Runfile
	- File with list of inputs in the following form (space-separated):
		SampleName Read1.fastq Read2.fastq

Output:
	- Dedupped and sorted bam files for each of the input samples
	- File with list of the output bam files
		
Error Handling:
	When a sample fails, either during alignment or deduplication, increment an error tracker
	If the number of failed samples surpasses a given threshold (specified in the runfile), terminate the workflow
	Only completed alignments will get their output bam file placed in the output file list


************************
Pseudocode for main loop
************************

foreach sample in Samples {
		
	- Create sample output directories
	- Create output file handles
	- alignReads (and verify alignment success)
	- markDuplicates (and verify dedup success)
	- QC on deduplicated file
}

********************************************************
 Helper Functions
********************************************************
*/

import unix;
import files;
import string;
import sys;
import io;

import pipelinefunctions.align_dedup;
import pipelinefunctions.miscellaneous;

/************
 Bam Checking
*************/
(boolean success) checkBam(string variables[string], file bamFile) {
	// Swift/T would try to use samtools_view2 even before bamFile is read. Added explicit wait command
	wait (bamFile) {
		int alignNum = samtools_view2(variables["SAMTOOLSDIR"], filename(bamFile));
		success = alignNum > 0;
	}
}

/*********
 Alignment
**********/
(file outputSam) alignReads(string sampleName, string read1, string read2, string rgheader) {
	/*
	This function returns a .sam file because samblaster requires it
	To minimize memory usage, delete the .sam file after a .bam file is made from it
	*/

	string AlignDir = strcat(vars["OUTPUTDIR"], "/", sampleName, "/align/");

	// Log file
	file alignedLog < strcat(AlignDir, sampleName, "_Alignment.log") >;

	// Use the specified alignment tool
	if (vars["ALIGNERTOOL"] == "BWAMEM") {
		// Directly return the .sam file created from bwa_mem
		outputSam, alignedLog = bwa_mem(vars["BWADIR"], read1, read2, vars["BWAINDEX"], 
				    [vars["BWAMEMPARAMS"]], string2int(vars["PBSCORES"]), rgheader
				   );
	} 
	else { // Novoalign is the default aligner
		// Directly return the .sam file created from novoalign
		outputSam, alignedLog = novoalign(vars["NOVOALIGNDIR"], read1, read2, vars["NOVOALIGNINDEX"],
				      [vars["NOVOALIGNPARAMS"]], string2int(vars["PBSCORES"]), rgheader
				     );
	}
}

/***************
 Mark Duplicates
****************/
(file dedupSortedBam) markDuplicates(string sampleName, file alignedSam, file alignedBam) {
	/*
	The input file used depends on the dedup program being used:
		alignedSam => Samblaster
		alignedBam => Picard or Novosort
	*/

	string AlignDir = strcat(vars["OUTPUTDIR"], "/", sampleName, "/align/");

	if (vars["MARKDUPLICATESTOOL"] == "SAMBLASTER") {
		file dedupsam < strcat(vars["TMPDIR"], "/align/", sampleName, ".wDedups.sam") >;
		file dedupbam < strcat(AlignDir, sampleName, ".wDedups.bam") >;
		file samLog < strcat(AlignDir, sampleName, "_SamblasterDedup.log") >; 
		file sortLog < strcat(AlignDir, sampleName, "_Sort.log") >;       	

		// Mark Duplicates
		dedupsam, samLog = samblaster(vars["SAMBLASTERDIR"], alignedSam);
		dedupbam = samtools_view(vars["SAMTOOLSDIR"], dedupsam, string2int(vars["PBSCORES"]), ["-u"]);
		// Delete the dedupsam file once dedupbam has been created
		rm(dedupsam);
		
		// Sort
		dedupSortedBam, sortLog = novosort(vars["NOVOSORTDIR"], dedupbam, vars["TMPDIR"],
					  string2int(vars["PBSCORES"]), ["--compression", "1"]
					 );
	}
	else if (vars["MARKDUPLICATESTOOL"] == "PICARD") {
		// Picard is unique in that it has a metrics file
		file metricsfile < strcat(AlignDir, sampleName, ".picard.metrics") >;
		file alignedsortedbam < strcat(AlignDir, sampleName, ".noDedups.sorted.bam") >;
		file picardLog < strcat(AlignDir, sampleName, "_PicardDedup.log") >;
		file sortLog < strcat(AlignDir, sampleName, "_Sort.log") >;
	
		// Sort
		alignedsortedbam, sortLog = novosort(vars["NOVOSORTDIR"], alignedBam, vars["TMPDIR"],
						     string2int(vars["PBSCORES"]), []
						    );
		// Mark Duplicates
		dedupSortedBam, picardLog, metricsfile = picard(vars["JAVADIR"], vars["PICARDDIR"],
							 	vars["TMPDIR"], alignedsortedbam
							       ); 
	}
	else {	//Novosort is the default duplicate marker
		file novoLog < strcat(AlignDir, sampleName, "_NovosortDedup.log") >;

		// Sort and Mark Duplicates in one step
		dedupSortedBam, novoLog = novosort(vars["NOVOSORTDIR"], alignedBam, vars["TMPDIR"],
					  string2int(vars["PBSCORES"]), ["--markDuplicates"]
					 );
	}
}

/*******************************************************
 Implementation
********************************************************/

/*************
 Parse runfile
**************/

//read-in the runfile with argument --runfile=<runfile_name>							       
argv_accept("runfile"); // return error if user supplies other flagged inputs					      
string configFilename = argv("runfile");

file configFile = input_file(configFilename);
string configFileData[] = file_lines(configFile);

// Gather variables
string vars[string] = getConfigVariables(configFileData);

/****************
 Find input files
*****************/

// Get input sample list
file sampleInfoFile = input_file(vars["SAMPLEINFORMATION"]);							       
string sampleLines[] = file_lines(sampleInfoFile);

/*****************
 Create directories
******************/

mkdir(vars["OUTPUTDIR"]);
mkdir(vars["TMPDIR"]);
mkdir(strcat(vars["OUTPUTDIR"], "/", vars["DELIVERYFOLDER"], "/docs"));

/**********************
Create the Failures.log
***********************/

// This file is initialized with an empty string, so it can be appended to later on
file failLog < strcat(vars["OUTPUTDIR"], "/", vars["DELIVERYFOLDER"], "/docs/Failures.log") > = write("");

/*******************************
 Create the output list file
********************************/

// This file is initialized with an empty string, so it can be appended to later on
file outList < strcat(vars["OUTPUTDIR"], "/BamFileList.txt") > = write("");

/*******************************************
 Copy input files for documentation purposes
*******************************************/

// Copy the runfile and sampleInfoFile to the docs directory for documentation purposes
file docRunfile < strcat(vars["OUTPUTDIR"], "/", vars["DELIVERYFOLDER"], "/docs/", basename_string(configFilename)
			) > = configFile;

file docSampleInfo < strcat(vars["OUTPUTDIR"], "/", vars["DELIVERYFOLDER"], "/docs/",				      
			    basename_string(filename(sampleInfoFile))						      
			   ) > = sampleInfoFile;

/*************************
 Main loop through samples
**************************/

foreach sample in sampleLines {
	
	/*****
	Parse sample specific information and construct RG header
	*****/
	string sampleInfo[] = split(sample, " ");
	string sampleName = sampleInfo[0];
	string read1 = sampleInfo[1];
	string read2 = sampleInfo[2];

	string rgheader = sprintf("@RG\tID:%s\tLB:%s\tPL:%s\tPU:%s\tSM:%s\tCN:%s", sampleName,
				  vars["SAMPLELB"], vars["SAMPLEPL"], sampleName, sampleName, vars["SAMPLECN"] 
				 );

	/****************************************************************************
	Alignment and Deduplication (per sample)
	****************************************************************************/

	/*****
	Create the sample output directories
	*****/

	string AlignDir = strcat(vars["OUTPUTDIR"], "/", sampleName, "/align/");
	string RealignDir = strcat(vars["OUTPUTDIR"], "/", sampleName, "/realign/"); 
	string VarcallDir = strcat(vars["OUTPUTDIR"], "/", sampleName, "/variant/");

	mkdir(AlignDir);
	mkdir(RealignDir);
	mkdir(VarcallDir);

	/*****
	Create output file handles
	*****/
	file alignedbam < strcat(AlignDir, sampleName, ".noDedups.bam") >;

	// These are temporary files: If piping is implemented, they would not be needed.
	file alignedsam < strcat(vars["TMPDIR"], "/align/", sampleName, ".noDedups.sam") >;

	/*****
	Alignment
	*****/
	alignedsam = alignReads(sampleName, read1, read2, rgheader);
	alignedbam = samtools_view(vars["SAMTOOLSDIR"], alignedsam, string2int(vars["PBSCORES"]), ["-u"]);

	// Verify alignment was successful
	if ( checkBam(vars, alignedbam) ) {

		/*****
		Deduplication
		*****/
		
		file dedupsortedbam < strcat(AlignDir, sampleName, ".wDedups.sorted.bam") >; 
		dedupsortedbam = markDuplicates(sampleName, alignedsam, alignedbam);

		// Verify deduplication was successful
		if ( checkBam(vars, dedupsortedbam) ) {

			// This will delete the raw aligned sam only after dedupsortedbam is written
			rm(alignedsam); 

			/*****
			Quality control of deduplicated file
			*****/

			// These are not specifically defined!					    
			file flagstats < strcat(AlignDir, sampleName, ".wDedups.sorted.bam", ".flagstats") >;

			flagstats = samtools_flagstat(vars["SAMTOOLSDIR"], dedupsortedbam);

			string stat[] = file_lines(flagstats);
			tot_mapped =  split(stat[4], " ")[0];
			tot_reads = split(stat[0], " ")[0];
			tot_dups = split(stat[3], " ")[0];

			perc_dup= string2float(tot_dups) * 100 / string2float(tot_reads);
			perc_mapped= string2float(tot_mapped) * 100 / string2float(tot_reads);

			// Message cutoff information
			string cutoff_info = strcat(sampleName, "\tPercentDuplication=", perc_dup,
						    ";DuplicationCutoff=", vars["DUP_CUTOFF"],
						    "\tPercentMapped=", perc_mapped,
						    ";MappingCutoff=", vars["MAP_CUTOFF"]
						   );
			// If both % duplicated and % mapped meet their cutoffs
			if ( perc_dup < string2float(vars["DUP_CUTOFF"]) && 
			     perc_mapped > string2float(vars["MAP_CUTOFF"]) ) {
				/*
				 SUCCESS
				*/
				printf(strcat("QC-Test SUCCESS: ", cutoff_info));
				// Add the deduplicated bam to the output list file
				append( outList, strcat( filename(dedupsortedbam), "\n" ) );
			}
			else {
				/*
				FAILURE
				*/
				string m = strcat("FAILURE: ", filename(dedupsortedbam),
						  " failed the QC test: ", cutoff_info
						 );
				append(failLog, m);
			}
		}
		// If the deduplication process fails, write a message to the failure log file
		else {
			string mssg = strcat("FAILURE: ", filename(dedupsortedbam), " contains no alignments. ",
					     "Check the log files within ", AlignDir, sampleName, " for details.\n"
					    );
			append(failLog, mssg);
		}
	}
	// If the alignment process fails, write a message to the failure log file
	else {
		string message = strcat("FAILURE: ", filename(alignedbam), " contains no alignments. ", 
					"Check ", AlignDir, sampleName, "_Alignment.log for details.\n"
				       );
		append(failLog, message);
	}		
}