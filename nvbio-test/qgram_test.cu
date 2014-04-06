/*
 * nvbio
 * Copyright (c) 2011-2014, NVIDIA CORPORATION. All rights reserved.
 * 
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *    * Redistributions of source code must retain the above copyright
 *      notice, this list of conditions and the following disclaimer.
 *    * Redistributions in binary form must reproduce the above copyright
 *      notice, this list of conditions and the following disclaimer in the
 *      documentation and/or other materials provided with the distribution.
 *    * Neither the name of the NVIDIA CORPORATION nor the
 *      names of its contributors may be used to endorse or promote products
 *      derived from this software without specific prior written permission.
 * 
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL NVIDIA CORPORATION BE LIABLE FOR ANY
 * DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 * ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

// qgram_test.cu
//
//#define CUFMI_CUDA_DEBUG
//#define CUFMI_CUDA_ASSERTS

#include <stdio.h>
#include <stdlib.h>
#include <vector>
#include <algorithm>
#include <nvbio/basic/timer.h>
#include <nvbio/basic/console.h>
#include <nvbio/basic/vector_wrapper.h>
#include <nvbio/basic/packedstream.h>
#include <nvbio/basic/string_set.h>
#include <nvbio/basic/shared_pointer.h>
#include <nvbio/io/reads/reads.h>
#include <nvbio/io/fmi.h>
#include <nvbio/qgram/qgram.h>
#include <nvbio/qgram/qgroup.h>
#include <nvbio/qgram/filter.h>

namespace nvbio {

// return the size of a given range
struct range_size
{
    typedef uint2  argument_type;
    typedef uint32 result_type;

    NVBIO_FORCEINLINE NVBIO_HOST_DEVICE
    uint32 operator() (const uint2 range) const { return range.y - range.x; }
};

// return 1 for non-empty ranges, 0 otherwise
struct valid_range
{
    typedef uint2  argument_type;
    typedef uint32 result_type;

    NVBIO_FORCEINLINE NVBIO_HOST_DEVICE
    uint32 operator() (const uint2 range) const { return range.y - range.x > 0 ? 1u : 0u; }
};

// query stats
//
struct Stats
{
    Stats() :
        build_time(0),
        unsorted_time(0),
        sorted_time(0),
        filter_time(0),
        queries(0),
        matches(0),
        occurrences(0) {}

    float   build_time;
    float   unsorted_time;
    float   sorted_time;
    float   filter_time;
    uint64  queries;
    uint64  matches;
    uint64  occurrences;
};

// build a set of q-grams from a given string, together with their sorted counterpart
//
template <typename genome_string>
void build_qgrams(
    const uint32                    Q,
    const uint32                    genome_len,
    const uint32                    genome_offset,
    const genome_string             genome,
    const uint32                    n_queries,
    thrust::device_vector<uint64>&  d_qgrams,
    thrust::device_vector<uint64>&  d_sorted_qgrams,
    thrust::device_vector<uint32>&  d_sorted_indices)
{
    // build the q-grams
    d_qgrams.resize( n_queries );
    thrust::transform(
        thrust::make_counting_iterator<uint32>(genome_offset),
        thrust::make_counting_iterator<uint32>(genome_offset) + n_queries,
        d_qgrams.begin(),
        string_qgram_functor<genome_string>( Q, 2u, genome_len, genome ) );

    // sort the q-grams
    d_sorted_qgrams = d_qgrams;
    d_sorted_indices.resize( n_queries );
    thrust::copy(
        thrust::make_counting_iterator<uint32>(0u),
        thrust::make_counting_iterator<uint32>(0u) + n_queries,
        d_sorted_indices.begin() );

    thrust::sort_by_key( d_sorted_qgrams.begin(), d_sorted_qgrams.end(), d_sorted_indices.begin() );
}

// build a q-gram index from a string
//
template <typename string_type>
void test_qgram_index_build(
    const uint32            Q,
    const uint32            string_len,
    const string_type       string,
          QGramIndexDevice& qgram_index)
{
    log_info(stderr, "  building q-gram index... started\n");

    Timer timer;
    timer.start();

    // build the q-gram index
    qgram_index.build(
        Q,              // q-gram size
        2u,             // implicitly convert N to A
        string_len,
        string,
        12u );

    cudaDeviceSynchronize();
    timer.stop();
    const float time = timer.seconds();

    log_info(stderr, "  building q-gram index... done\n");
    log_info(stderr, "    unique q-grams : %.2f M q-grams\n", 1.0e-6f * float( qgram_index.n_unique_qgrams ));
    log_info(stderr, "    throughput     : %.1f M q-grams/s\n", 1.0e-6f * float( string_len ) / time);
    log_info(stderr, "    memory usage   : %.1f MB\n", float( qgram_index.used_device_memory() ) / float(1024*1024) );

    log_info(stderr, "  querying q-gram index... started\n");
}

// build a q-gram set-index from a string-set
//
template <typename string_type>
void test_qgram_set_index_build(
    const uint32            Q,
    const uint32            n_strings,
    const uint32            string_len,
    const string_type       string,
    const uint32*           string_index,
    QGramSetIndexDevice&    qgram_index)
{
    log_info(stderr, "  building q-gram set-index... started\n");

    typedef ConcatenatedStringSet<
        typename string_type::iterator,
        const uint32*>              string_set_type;

    const string_set_type string_set(
        n_strings,
        string.begin(),
        string_index );

    Timer timer;
    timer.start();

    // build the q-gram set index
    qgram_index.build(
        Q,              // q-gram size
        2u,             // implicitly convert N to A
        string_set,
        12u );

    cudaDeviceSynchronize();
    timer.stop();
    const float time = timer.seconds();

    log_info(stderr, "  building q-gram set-index... done\n");
    log_info(stderr, "    unique q-grams : %.2f M q-grams\n", 1.0e-6f * float( qgram_index.n_unique_qgrams ));
    log_info(stderr, "    throughput     : %.1f M q-grams/s\n", 1.0e-6f * float( string_len ) / time);
    log_info(stderr, "    memory usage   : %.1f MB\n", float( qgram_index.used_device_memory() ) / float(1024*1024) );
}

// build a q-group index from a string
//
template <typename string_type>
void test_qgroup_index_build(
    const uint32            Q,
    const uint32            string_len,
    const string_type       string,
    QGroupIndexDevice&      qgram_index)
{
    log_info(stderr, "  building q-group index... started\n");

    Timer timer;
    timer.start();

    // build the q-group index
    qgram_index.build(
        Q,              // q-group size
        2u,             // implicitly convert N to A
        string_len,
        string );

    cudaDeviceSynchronize();
    timer.stop();
    const float time = timer.seconds();

    log_info(stderr, "  building q-group index... done\n");
    log_info(stderr, "    unique q-grams : %.2f M q-grams\n", 1.0e-6f * float( qgram_index.n_unique_qgrams ));
    log_info(stderr, "    throughput     : %.1f M q-grams/s\n", 1.0e-6f * float( string_len ) / time);
    log_info(stderr, "    memory usage   : %.1f MB\n", float( qgram_index.used_device_memory() ) / float(1024*1024) );

    log_info(stderr, "  querying q-group index... started\n");
}

// test a generic q-gram index query, both using plain queries and with a q-gram filter
//
template <typename qgram_index_type, typename genome_string>
void test_qgram_index_query(
          qgram_index_type& qgram_index,
    const uint32            n_queries,
    const uint32            genome_len,
    const uint32            genome_offset,
    const genome_string     genome,
          Stats&            stats)
{
    const uint32 Q = qgram_index.Q;

    // prepare some vectors to store the query qgrams
    thrust::device_vector<uint64>  d_qgrams( n_queries );
    thrust::device_vector<uint64>  d_sorted_qgrams( n_queries );
    thrust::device_vector<uint32>  d_sorted_indices( n_queries );

    build_qgrams(
        Q,
        genome_len,
        genome_offset,
        genome,
        n_queries,
        d_qgrams,
        d_sorted_qgrams,
        d_sorted_indices );

    // prepare a vector to store the query results
    thrust::device_vector<uint2>  d_ranges( n_queries );

    log_info(stderr, "  querying q-gram index... started\n");

    Timer timer;
    timer.start();

    // search the query q-grams in the index
    thrust::transform(
        d_qgrams.begin(),
        d_qgrams.begin() + n_queries,
        d_ranges.begin(),
        nvbio::plain_view( qgram_index ) );

    cudaDeviceSynchronize();
    timer.stop();
    const float unsorted_time = timer.seconds();

    timer.start();

    // and now repeat the same operation with the sorted q-grams
    thrust::transform(
        d_sorted_qgrams.begin(),
        d_sorted_qgrams.begin() + n_queries,
        d_ranges.begin(),
        nvbio::plain_view( qgram_index ) );

    cudaDeviceSynchronize();
    timer.stop();
    const float sorted_time = timer.seconds();

    const uint32 n_occurrences = thrust::reduce(
        thrust::make_transform_iterator( d_ranges.begin(), range_size() ),
        thrust::make_transform_iterator( d_ranges.begin(), range_size() ) + n_queries );

    const uint32 n_matches = thrust::reduce(
        thrust::make_transform_iterator( d_ranges.begin(), valid_range() ),
        thrust::make_transform_iterator( d_ranges.begin(), valid_range() ) + n_queries );

    stats.queries       += n_queries;
    stats.unsorted_time += unsorted_time;
    stats.sorted_time   += sorted_time;
    stats.matches       += n_matches;
    stats.occurrences   += n_occurrences;

    log_info(stderr, "  querying q-gram index... done\n");
    log_info(stderr, "    unsorted throughput : %.2f B q-grams/s\n", (1.0e-9f * float( stats.queries )) / stats.unsorted_time);
    log_info(stderr, "    sorted   throughput : %.2f B q-grams/s\n", (1.0e-9f * float( stats.queries )) / stats.sorted_time);
    log_info(stderr, "    matches             : %.2f M\n", 1.0e-6f * float( stats.matches ) );
    log_info(stderr, "    occurrences         : %.3f B\n", 1.0e-9f * float( stats.occurrences ) );

    log_info(stderr, "  q-gram filter... started\n");

    //
    // search the sorted query q-grams with a q-gram filter
    //

    QGramFilter qgram_filter;

    timer.start();

    qgram_filter.enact(
        nvbio::plain_view( qgram_index ),
        n_queries,
        d_sorted_qgrams.begin(),
        d_sorted_indices.begin() );

    cudaDeviceSynchronize();
    timer.stop();
    const float filter_time = timer.seconds();

    stats.filter_time += filter_time;

    log_info(stderr, "  q-gram filter... done\n");
    log_info(stderr, "    throughput : %.2f B q-grams/s\n", (1.0e-9f * float( stats.queries )) / stats.filter_time);
}

// main test entry point
//
int qgram_test(int argc, char* argv[])
{
    uint32 n_qgrams      = 10000000;
    uint32 n_queries     = 10000000;
    uint32 queries_batch = 10000000;
    char*  reads = "./data/SRR493095_1.fastq.gz";
    char*  index = "./data/human.NCBI36/Homo_sapiens.NCBI36.53.dna.toplevel.fa";

    for (int i = 0; i < argc; ++i)
    {
        if (strcmp( argv[i], "-qgrams" ) == 0)
            n_qgrams = uint32( atoi( argv[++i] ) )*1000u;
        else if (strcmp( argv[i], "-queries" ) == 0)
            n_queries = uint32( atoi( argv[++i] ) )*1000u;
        else if (strcmp( argv[i], "-batch" ) == 0)
            queries_batch = uint32( atoi( argv[++i] ) )*1000u;
        else if (strcmp( argv[i], "-reads" ) == 0)
            reads = argv[++i];
        else if (strcmp( argv[i], "-index" ) == 0)
            index = argv[++i];
    }

    log_info(stderr, "q-gram test... started\n");

    const io::QualityEncoding qencoding = io::Phred33;

    log_info(stderr, "  loading reads... started\n");

    SharedPointer<io::ReadDataStream> read_data_file(
        io::open_read_file(
            reads,
            qencoding,
            uint32(-1),
            uint32(-1) ) );

    if (read_data_file == NULL || read_data_file->is_ok() == false)
    {
        log_error(stderr, "    failed opening file \"%s\"\n", reads);
        return 1u;
    }

    const uint32 batch_size = uint32(-1);
    const uint32 batch_bps  = n_qgrams;

    // load a batch of reads
    SharedPointer<io::ReadData> h_read_data( read_data_file->next( batch_size, batch_bps ) );
    
    // build its device version
    io::ReadDataCUDA d_read_data( *h_read_data );

    log_info(stderr, "  loading reads... done\n");

    // fetch the actual string
    typedef io::ReadData::const_read_stream_type string_type;

    const uint32      n_strings      = d_read_data.size();
    const uint32      string_len     = h_read_data->read_index()[ n_strings ];
    const string_type string         = string_type( d_read_data.read_stream() );
    const uint32*     string_index   = d_read_data.read_index();

    log_info(stderr, "    strings: %u\n", n_strings);
    log_info(stderr, "    symbols: %.3f M\n", 1.0e-6f * float(string_len));

    io::FMIndexDataRAM fmi;
    if (!fmi.load( index, io::FMIndexData::GENOME ))
    {
        log_error(stderr, "    failed loading index \"%s\"\n", index);
        return 1u;
    }

    // build its device version
    const io::FMIndexDataCUDA fmi_cuda( fmi, io::FMIndexDataCUDA::GENOME );

    typedef io::FMIndexData::stream_type genome_type;

    const uint32      genome_len = fmi_cuda.genome_length();
    const genome_type genome( fmi_cuda.genome_stream() );

    // clamp the total number of queries
    n_queries = nvbio::min( n_queries, genome_len );

    // test q-gram index
    {
        log_visible(stderr, "  testing q-gram index... started\n");

        QGramIndexDevice qgram_index;

        test_qgram_index_build(
            20u,
            string_len,
            string,
            qgram_index );

        Stats stats;

        for (uint32 genome_begin = 0; genome_begin < n_queries; genome_begin += queries_batch)
        {
            const uint32 genome_end = nvbio::min( genome_begin + queries_batch, n_queries );

            test_qgram_index_query(
                qgram_index,
                genome_end - genome_begin,
                genome_len,
                genome_begin,
                genome,
                stats );
        }

        log_visible(stderr, "  testing q-gram index... done\n");
    }

    // test q-gram set-index
    {
        log_visible(stderr, "  testing q-gram set-index... started\n");

        QGramSetIndexDevice qgram_index;

        test_qgram_set_index_build(
            20u,
            n_strings,
            string_len,
            string,
            string_index,
            qgram_index );

        Stats stats;

        for (uint32 genome_begin = 0; genome_begin < n_queries; genome_begin += queries_batch)
        {
            const uint32 genome_end = nvbio::min( genome_begin + queries_batch, n_queries );

            test_qgram_index_query(
                qgram_index,
                genome_end - genome_begin,
                genome_len,
                genome_begin,
                genome,
                stats );
        }

        log_visible(stderr, "  testing q-gram set-index... done\n");
    }

    // test q-group index
    {
        log_visible(stderr, "  testing q-group index... started\n");

        QGroupIndexDevice qgram_index;

        test_qgroup_index_build(
            16u,
            string_len,
            string,
            qgram_index );

        Stats stats;

        for (uint32 genome_begin = 0; genome_begin < n_queries; genome_begin += queries_batch)
        {
            const uint32 genome_end = nvbio::min( genome_begin + queries_batch, n_queries );

            test_qgram_index_query(
                qgram_index,
                genome_end - genome_begin,
                genome_len,
                genome_begin,
                genome,
                stats );
        }

        log_visible(stderr, "  testing q-group index... done\n");
    }

    log_info(stderr, "q-gram test... done\n" );
    return 0;
}

} // namespace nvbio
